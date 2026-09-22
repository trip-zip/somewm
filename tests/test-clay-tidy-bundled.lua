-- Pinned bundled compositions, with deterministic clock/tags/icon buffers.
-- The complete somewmrc.lua is also exercised separately in the sandbox.
local awful = require('awful')
local wibox = require('wibox')
local beautiful = require('beautiful')
local cairo = require('lgi').cairo
local example = require('_clay_example')
local checks = example.batch()
local utils = require('_utils')
local s = screen[1]
local bar, c, clock, previous
local buffers = {}
local function image(size, red, green, blue)
    local surface = cairo.ImageSurface.create(cairo.Format.ARGB32, size, size)
    local cr = cairo.Context(surface)
    cr:set_source_rgb(red, green, blue); cr:paint()
    buffers[#buffers + 1] = surface
    return surface
end
-- Independent of the tree reducer: intrinsic square sources fill the
-- authored host thickness, and their actual center pixels remain visible.
local function icons(size, titlebar)
    local expected = titlebar and {'#0000ff','#00ff00','#ffff00','#ff0000'}
        or {'#ff0000','#00ff00'}
    local count = 0
    for line in awesome._clay_tree(s):gmatch('[^\n]+') do
        if line:match('^    %x+ .*image image ') then
            local x,y,w,h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            x,y,w,h = tonumber(x),tonumber(y),tonumber(w),tonumber(h)
            count = count + 1
            assert(w == size and h == size, 'icon allocation: '..line)
            example.pixel(x+math.floor(w/2),y+math.floor(h/2),assert(expected[count]))
        end
    end
    assert(count == #expected, 'missing visible bundled icon')
end
local function resized(size, titlebar)
    return function(n)
        if n == 1 then
            if titlebar then awful.titlebar(c, {size=size}) else bar.height=size end
            return
        end
        if n < 4 then return end
        icons(size, titlebar)
        example.save('bundled-icons-'..(titlebar and 'titlebar-' or 'bar-')..size,
            awesome._clay_tree(s))
        return true
    end
end
local function settled(name)
    return function(n)
        local dump = awesome._clay_tree(s)
        if n<3 or previous~=dump then
            previous=dump
            assert(n<30, name .. ' did not settle')
            return
        end
        checks.check(name, dump)
        return true
    end
end
require('_runner').run_steps {
    function()
        beautiful.font = 'sans 10'
        beautiful.wibar_height = 32
        beautiful.bg_normal, beautiful.bg_focus = '#282828', '#3c3836'
        beautiful.fg_normal, beautiful.fg_focus = '#ffffff', '#ffffff'
        beautiful.systray_paddings, beautiful.systray_icon_spacing = 0, 0
        beautiful.awesome_icon = image(24, 1, 0, 0)
        beautiful.layout_tile = image(240, 0, 1, 0)
        s.selected_tag.name = 'dev'
        s.selected_tag.layout = awful.layout.suit.tile
        for _, name in ipairs{'web','chat','media','misc'} do
            awful.tag.add(name, {screen=s, layout=awful.layout.suit.tile})
        end
        for _, item in ipairs(systray_item.get_items()) do item.status='Passive' end
        local launcher = awful.widget.launcher {image=beautiful.awesome_icon,
            menu=awful.menu {items={}}}
        local tags = awful.widget.taglist {screen=s, filter=awful.widget.taglist.filter.all}
        local prompt = awful.widget.prompt()
        local tasks = awful.widget.tasklist {screen=s,
            filter=awful.widget.tasklist.filter.currenttags}
        clock = wibox.widget.textclock('Fri Sep 12  09:14')
        local clock_box = wibox.container.background(
            wibox.container.margin(clock,8,8,0,0), '#3c3836')
        bar = awful.wibar {screen=s, position='top', widget={
            layout=wibox.layout.stack,
            {layout=wibox.layout.align.horizontal,
                {layout=wibox.layout.fixed.horizontal, launcher,tags,prompt,tasks},
                {widget=wibox.container.background},
                {layout=wibox.layout.fixed.horizontal, wibox.widget.systray(),
                    awful.widget.layoutbox(s)}},
            {clock_box, halign='center', widget=wibox.container.place}}}
        return true
    end,
    settled('tidy-bundled-wibar'),
    function() icons(32, false); return true end,
    resized(48, false),
    resized(32, false),
    function()
        bar:remove()
        s.selected_tag.gap = 0
        awful.spawn{assert(utils.binary_or_skip('./build-test/test-transient-client')), 'CLIENT_A'}
        return true
    end,
    function(n)
        c = utils.find_client_by_class('CLIENT_A')
        if not c then assert(n<30, 'bundled titlebar client did not map'); return end
        c.floating, c.shadow, c.border_width = false, false, 2
        c.name = 'Example'
        c.icon = image(512, 0, 0, 1)._native
        for _, state in ipairs{'normal','focus'} do
            beautiful['titlebar_close_button_' .. state] = image(240, 1, 0, 0)
            for _, active in ipairs{'active','inactive'} do
                beautiful['titlebar_floating_button_' .. state .. '_' .. active] = image(240, 0, 1, 0)
                beautiful['titlebar_maximized_button_' .. state .. '_' .. active] = image(240, 1, 1, 0)
            end
        end
        local buttons = {awful.button({},1,function()
            c:activate {context='titlebar',action='mouse_move'}
        end), awful.button({},3,function()
            c:activate {context='titlebar',action='mouse_resize'}
        end)}
        awful.titlebar(c,{size=30}).widget = {
            {awful.titlebar.widget.iconwidget(c), buttons=buttons,
                layout=wibox.layout.fixed.horizontal},
            {{halign='center',widget=awful.titlebar.widget.titlewidget(c)},
                buttons=buttons,layout=wibox.layout.flex.horizontal},
            {awful.titlebar.widget.floatingbutton(c), awful.titlebar.widget.maximizedbutton(c),
                awful.titlebar.widget.closebutton(c),layout=wibox.layout.fixed.horizontal},
            layout=wibox.layout.align.horizontal}
        previous=nil
        return true
    end,
    settled('tidy-bundled-titlebar'),
    function() icons(30, true); return true end,
    resized(42, true),
    resized(30, true),
    function() c:kill(); return true end,
    checks.finish,
}
