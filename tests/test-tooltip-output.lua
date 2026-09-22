-- A delayed tooltip and a button-bound popup keep their opener's output.
-- Use real input and a widget shared by both outputs: widget identity alone
-- cannot say which occurrence opened the attachment.
local runner = require('_runner')
local awful = require('awful')
local wibox = require('wibox')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local left, right, bars, tip, popup, target
local function pointer(action, s, x, y)
    awful.spawn {'./build-test/test-virtual-pointer-client', action,
        tostring(s.geometry.x + (x or 30)), tostring(s.geometry.y + (y or 15)),
        tostring(right.geometry.x + right.geometry.width),
        tostring(math.max(left.geometry.height, right.geometry.height)), 'left'}
end
local function painted(w, s)
    local g = w:geometry()
    assert(w.screen == s, 'attachment assigned screen '..w.screen.index..', opener screen '..s.index)
    local bounds=s.geometry
    assert(g.x>=bounds.x and g.y>=bounds.y and g.x+g.width<=bounds.x+bounds.width
        and g.y+g.height<=bounds.y+bounds.height, 'attachment extends beyond opener output')
    local r, green, b = capture.read(surface(s.content), g.x-s.geometry.x+2, g.y-s.geometry.y+2)
    assert(r > 240 and green < 10 and b < 10, 'attachment background missing on opener output')
end
runner.run_steps {
    function() assert(awesome._test_add_output(800,600)); return true end,
    function() return screen.count() >= 2 or nil end,
    function()
        for s in screen do
            if not left or s.geometry.x < left.geometry.x then left=s end
            if not right or s.geometry.x > right.geometry.x then right=s end
        end
        target=wibox.widget.textbox('opener')
        bars={}
        for _, s in ipairs{left,right} do
            bars[#bars+1]=awful.wibar{screen=s,position='top',height=30,widget=target}
        end
        tip=awful.tooltip{objects={target},text='secondary tooltip',delay_show=0.2,
            bg='#ff0000',border_width=0,margin_leftright=8,margin_topbottom=8,
            shape=require('gears.shape').rectangle}
        popup=awful.popup{visible=false,bg='#ff0000',shadow=false,border_width=0,
            preferred_positions={'bottom'},preferred_anchors={'front'},
            widget=wibox.container.margin(wibox.widget.textbox('popup'),8,8,8,8)}
        popup:bind_to_widget(target,1)
        return true
    end,
    function(n) if n<4 then return end; pointer('move',right); return true end,
    function(n)
        if not tip.visible or n<5 then assert(n<25,'tooltip did not open'); return end
        painted(tip:get_wibox(),right)
        io.stderr:write('[PASS] delayed tooltip paints on secondary opener output\n')
        pointer('click',right)
        return true
    end,
    function(n)
        if not popup.visible or n<3 then assert(n<25,'bound popup did not open'); return end
        painted(popup,right)
        popup.visible=false
        pointer('move',left)
        return true
    end,
    function(n)
        if n<8 then return end
        assert(tip.visible,'shared opener did not reopen tooltip')
        painted(tip:get_wibox(),left)
        io.stderr:write('[PASS] bound popup follows opener output; shared tooltip returns to primary\n')
        tip:remove_from_object(target); tip.hide(); popup.visible=false
        tip=awful.tooltip{objects={bars[2]},text='whole bar tooltip',
            mode='outside',preferred_positions={'bottom'},preferred_alignments={'front'},
            bg='#ff0000',border_width=0,margin_leftright=8,margin_topbottom=8,
            shape=require('gears.shape').rectangle}
        pointer('move',right)
        return true
    end,
    function(n)
        if n<8 then return end
        assert(tip.visible,'whole-bar tooltip did not open')
        painted(tip:get_wibox(),right)
        io.stderr:write('[PASS] whole-wibar tooltip uses its Lua host on secondary output\n')
        tip:remove_from_object(bars[2]); tip.hide()
        pointer('move',left)
        bars[2].position='bottom'
        tip=awful.tooltip{objects={bars[2]},text='bottom-right default tooltip',
            bg='#ff0000',border_width=0,margin_leftright=8,margin_topbottom=8,
            shape=require('gears.shape').rectangle}
        return true
    end,
    function(n)
        if n<4 then return end
        pointer('move',right,right.geometry.width-30,right.geometry.height-15)
        return true
    end,
    function(n)
        if n<8 then return end
        assert(tip.visible,'bottom-wibar default tooltip did not open')
        painted(tip:get_wibox(),right)
        io.stderr:write('[PASS] default tooltip stays inside top-left and bottom-right output edges\n')
        tip:remove_from_object(bars[2]); tip.hide()
        for _,bar in ipairs(bars) do bar:remove() end
        return true
    end,
}
