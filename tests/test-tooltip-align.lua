local runner = require('_runner')
local awful = require('awful')
local beautiful = require('beautiful')
local wibox = require('wibox')
local bar, target, tip
local saved_align = beautiful.tooltip_align

runner.run_steps {
    function()
        beautiful.tooltip_align = nil
        local aligned = awful.tooltip { align='top_left', text='aligned' }
        assert(aligned.align == 'top_left')
        local invalid = awful.tooltip { align='unknown', text='invalid' }
        assert(invalid.align == 'right' and invalid._private.align == nil)
        for _, value in ipairs{'unknown', false, 42, {}} do
            aligned:set_align(value)
            assert(aligned.align == 'top_left')
        end
        aligned:set_align(nil)
        assert(aligned.align == 'top_left')
        local default = awful.tooltip { text='default' }
        assert(default.align == 'right' and default._private.align == nil)
        beautiful.tooltip_align = 'bottom_left'
        assert(awful.tooltip { text='themed' }.align == 'bottom_left')
        assert(awful.tooltip { align='top', text='explicit' }.align == 'top')
        beautiful.tooltip_align = 'unknown'
        assert(awful.tooltip { text='invalid theme' }._private.align == nil)
        beautiful.tooltip_align = nil
        io.stderr:write('[PASS] tooltip align validates constructor, setter and theme values\n')
        aligned.show(wibox.widget.textbox('attachment target'))
        aligned.hide()
        for name, own in pairs {
            right=1, left=7, top=5, bottom=3,
            top_right=2, top_left=8, bottom_right=0, bottom_left=6,
        } do
            aligned.align = name
            local a = aligned.wibox.drawin.attachment
            assert(a.parent == 0 and a.own == own, name)
            assert(a.hover == false and a.kind == 1, name)
        end
        aligned.align = 'right'
        aligned.preferred_positions = {'bottom'}
        aligned.preferred_alignments = {'front'}
        local a = aligned.wibox.drawin.attachment
        assert(a.parent == 2 and a.own == 0, 'preferred positions must override align')
        aligned.preferred_positions = nil
        aligned.mode = 'outside'
        a = aligned.wibox.drawin.attachment
        assert(a.parent == 0 and a.own == 2, 'outside mode must ignore align')
        io.stderr:write('[PASS] all eight align attachments, preferred positions and outside mode\n')
        target = wibox.widget.textbox('opener')
        bar = awful.wibar { screen=screen[1], position='top', height=80, widget=target }
        tip = awful.tooltip { objects={target}, text='aligned tooltip', align='right',
            border_width=0, gaps=2, margin_leftright=4, margin_topbottom=4 }
        return true
    end,
    function(n)
        if n < 3 then return end
        local g = screen[1].geometry
        awful.spawn {'./build-test/test-virtual-pointer-client', 'move',
            '300', '30', tostring(g.width), tostring(g.height)}
        return true
    end,
    function(n)
        if not tip.visible or n < 4 then assert(n < 30, 'tooltip did not open'); return end
        local g, p = tip.wibox:geometry(), mouse.coords()
        local s = screen[1].geometry
        assert(p.x < s.x + s.width/2 and p.y < s.y + s.height/2)
        assert(g.width > 0 and g.height > 0)
        assert(g.x > p.x, 'right tooltip must open right of pointer')
        assert(math.abs(g.y + g.height/2 - p.y) <= 1, 'right tooltip must center on pointer')
        io.stderr:write('[PASS] explicit right opens right of pointer and vertically centered\n')
        tip:remove_from_object(target)
        tip.hide()
        tip = awful.tooltip { objects={target}, text='aligned tooltip', align='bottom_left',
            border_width=0, gaps=2, margin_leftright=4, margin_topbottom=4 }
        tip.show(target)
        return true
    end,
    function(n)
        if n < 4 then return end
        local g, p = tip.wibox:geometry(), mouse.coords()
        assert(g.width > 0 and g.height > 0)
        assert(g.y > p.y, 'bottom_left tooltip must open below pointer')
        assert(g.x + g.width <= p.x, 'bottom_left tooltip must end at or left of pointer')
        io.stderr:write('[PASS] explicit bottom_left opens below pointer and extends left\n')
        tip:remove_from_object(target)
        tip.hide()
        bar:remove()
        beautiful.tooltip_align = saved_align
        return true
    end,
}
