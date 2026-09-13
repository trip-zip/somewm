-- Fixtures for the handwritten task-4 goldens. Never record expectations.
local runner = require('_runner')
local awful = require('awful')
local wibox = require('wibox')
local example = require('_clay_example')
local M = {}
function M.run(name)
    local s = screen[1]
    local bar, popup, tooltip, target, pid
    local notifications = {}
    local previous, popup_before, target_before
    local tooltip_clicks=0
    local notification_boxes
    local layer_report=os.tmpname()
    local stretch_pid, stretch_report=nil,os.tmpname()
    local function text(value) return wibox.widget.textbox(value) end
    runner.run_steps {
        function()
            require('gears.wallpaper').set('#123456')
            bar = awful.wibar { screen=s, position='top', height=28,
                bg='#00ff00', widget=text('bar') }
            if name == 'floating-widget-anchored-to-another-widget' then
                target = text('clock')
                bar:setup { layout=wibox.layout.align.horizontal, expand='outside',
                    text('menu'), target, text('status') }
                popup = awful.popup { screen=s, visible=false, ontop=true,
                    bg='#ff0000', border_width=0, shadow=false,
                    preferred_positions={'bottom'}, preferred_anchors={'middle'},
                    widget=text('Calendar') }
            elseif name == 'hover-tooltip' then
                target = text('wifi'); bar.widget = target
                target:buttons {awful.button({},1,function() tooltip_clicks=tooltip_clicks+1 end)}
                tooltip = awful.tooltip { objects={target}, text='Connected to Home Wi-Fi',
                    mode='outside', preferred_positions={'bottom'}, preferred_alignments={'middle'},
                    gaps=6, margin_leftright=4, margin_topbottom=4,
                    bg='#ff0000', border_width=0, shape=require('gears.shape').rectangle }
            elseif name == 'notification-stack' then
                local naughty = require('naughty')
                local beautiful = require('beautiful')
                beautiful.notification_spacing = 8
                beautiful.notification_width = 320
                beautiful.notification_padding = 16
                naughty.connect_signal('request::display', function(n)
                    require('naughty.layout.box') { notification=n, border_width=0,
                        shadow=false, bg='#ff0000', widget_template={widget=naughty.widget.message} }
                end)
                for _, value in ipairs{'Download complete','Battery low','New message'} do
                    notifications[#notifications+1] = naughty.notification {
                        screen=s, position='top_right', message=value, timeout=0 }
                end
            elseif name == 'centered-launcher' then
                popup = awful.popup { screen=s, visible=true, ontop=true,
                    bg='#ff0000', border_width=0, shadow=false,
                    minimum_width=600, maximum_width=600,
                    placement=awful.placement.centered,
                    widget={layout=wibox.layout.fixed.vertical, text('Search'),
                        {layout=wibox.layout.fixed.vertical,
                            text('Terminal'), text('Browser'), text('Files')}} }
            elseif name == 'layer-shell-overlay' then
                local binary = assert(require('_utils').binary_or_skip('./build-test/test-layer-client'))
                pid = awful.spawn {binary, '--namespace', 'test-layer-overlay',
                    '--keyboard','none','--layer','overlay','--anchor','top,right',
                    '--size','240,120','--exclusive-zone','0','--margins','16,12,0,0',
                    '--configure-report',layer_report,'--color','ff808080'}
            end
            return true
        end,
        function(n)
            if n < 3 then return end
            if name == 'floating-widget-anchored-to-another-widget' then
                popup:move_next_to {widget=target,x=600,y=0,width=40,height=28}
            elseif name == 'hover-tooltip' then
                awful.spawn {'./build-test/test-virtual-pointer-client','move','12','12','1280','720'}
            end
            return true
        end,
        function(n)
            local dump = awesome._clay_tree(s)
            if tooltip and not tooltip.visible then assert(n<30,'real input did not show tooltip'); return end
            if dump ~= previous or not dump:find('converted',1,true)
                or (pid and not dump:find('test-layer-overlay',1,true)) then
                previous = dump
                assert(n < 30, name .. ' did not settle:\n' .. dump)
                return
            end
            local ok, err = pcall(example.check, name, dump)
            if not ok then
                local f = assert(io.open('/tmp/task4-first-difference-' .. name .. '.txt', 'w'))
                f:write(tostring(err), '\n'); f:close()
                error(err)
            end
            if name == 'layer-shell-overlay' then
                assert(dump:find('offset -12,16 band 100',1,true))
                assert(dump:find('parent RIGHT_TOP own RIGHT_TOP',1,true))
                assert(dump:find('box 1028,16 240x120',1,true))
                local f=assert(io.open(layer_report)); local size=f:read('*a'); f:close()
                assert(size=='240 120\n','layer configure must equal solved surface: '..size)
                example.pixel(1030,18,'#808080') -- above normal bar
                example.pixel(1030,40,'#808080')
                example.pixel(1026,40,'#123456')
                io.stderr:write('[PASS] layer overlay anchors/margin inputs, painted solved box and client configure240x120\n')
            end
            if name == 'floating-widget-anchored-to-another-widget' then
                local a = popup.drawin.attachment
                assert(a.parent==5 and a.own==3 and a.target==require('wibox.clay').identity(target))
                local id, x, y, width, height = dump:match('(%x+) +wibox.widget.textbox[^\n]- box (%d+),(%d+) (%d+)x(%d+)\n[^\n]-text "clock"')
                assert(id, 'clock element missing')
                local g=popup:geometry()
                assert(dump:find('target '..id..' parent BOTTOM_CENTER own TOP_CENTER',1,true))
                assert(math.abs(g.x+g.width/2-tonumber(x)-tonumber(width)/2)<=1)
                assert(g.y==tonumber(y)+tonumber(height))
                example.pixel(g.x+2,g.y+2,'#ff0000')
                popup_before=g; target_before=tonumber(x)
                bar:setup {layout=wibox.layout.align.horizontal, expand='inside',
                    target,text('menu'),text('status')}
            end
            return true
        end,
        function(n)
            if not popup_before then return true end
            local dump=awesome._clay_tree(s)
            local x,y,width,height=dump:match('wibox.widget.textbox[^\n]- box (%d+),(%d+) (%d+)x(%d+)\n[^\n]-text "clock"')
            local g=popup:geometry()
            if not x or tonumber(x)==target_before or g.x==popup_before.x then
                assert(n<30,'clock/popup did not move'); return
            end
            assert(math.abs(g.x+g.width/2-tonumber(x)-tonumber(width)/2)<=1)
            assert(g.y==tonumber(y)+tonumber(height))
            example.pixel(math.max(0,g.x+2),g.y+2,'#ff0000')
            example.pixel(popup_before.x+2,popup_before.y+2,'#123456')
            io.stderr:write('[PASS] popup target ID, BOTTOM_CENTER/TOP_CENTER, moved bar target and old/new painted boxes\n')
            return true
        end,
        function()
            if name~='layer-shell-overlay' then return true end
            stretch_pid=awful.spawn {'./build-test/test-layer-client','--namespace','test-layer-stretch',
                '--keyboard','none','--layer','overlay','--anchor','top,left,right',
                '--size','0,80','--exclusive-zone','0','--margins','10,12,0,16',
                '--configure-report',stretch_report,'--color','ff0000ff'}
            return true
        end,
        function(n)
            if not stretch_pid then return true end
            local dump=awesome._clay_tree(s)
            local leaf=dump:match('layer.surface test%-layer%-stretch[^\n]+')
            if not leaf then assert(n<20,'stretched overlay did not map'); return end
            assert(leaf:find('box 16,10 1252x80',1,true),leaf)
            local f=assert(io.open(stretch_report)); local size=f:read('*a'); f:close()
            assert(size=='1252 80\n',size)
            assert(s.workarea.y==28,'overlay reserved workarea')
            example.pixel(18,12,'#0000ff'); example.pixel(1266,12,'#0000ff')
            example.pixel(14,26,'#00ff00')
            io.stderr:write('[PASS] two-sided layer anchor grows; protocol margins inset flow surface; configure1252x80 and pixels agree\n')
            return true
        end,
        function()
            if name~='centered-launcher' then return true end
            local g=popup:geometry()
            assert(g.width==600 and g.x==340 and math.abs(g.y+g.height/2-360)<=1)
            assert(awesome._clay_tree(s):find('parent CENTER own CENTER',1,true))
            example.pixel(g.x+2,g.y+2,'#ff0000')
            popup.visible=false
            local b=require('beautiful')
            b.menubar_bg_normal='#0000ff'; b.menubar_border_width=0
            local menubar=require('menubar')
            menubar.menu_gen.generate=function(done) done({}) end
            menubar.show(s)
            return true
        end,
        function(n)
            if name~='centered-launcher' then return true end
            local dump=awesome._clay_tree(s)
            if dump:find('Terminal',1,true) or not dump:find('Run:',1,true) then
                assert(n<30,'menubar did not replace launcher'); return
            end
            local x,y,w,h=dump:match('LAUNCHER [^\n]- box (%d+),(%d+) (%d+)x(%d+)')
            assert(tonumber(w)==600 and tonumber(x)==340)
            assert(math.abs(tonumber(y)+tonumber(h)/2-360)<=1)
            example.pixel(tonumber(x)+2,tonumber(y)+tonumber(h)-2,'#0000ff')
            _keygrabber.inject('z',true); _keygrabber.inject('z',false)
            return true
        end,
        function(n)
            if name~='centered-launcher' then return true end
            local dump=awesome._clay_tree(s)
            if not dump:find('Run: z',1,true) then assert(n<10,'prompt did not consume injected key:\n'..dump); return end
            _keygrabber.inject('Escape',true); _keygrabber.inject('Escape',false)
            return true
        end,
        function(n)
            if name~='centered-launcher' then return true end
            if awesome._clay_tree(s):find('LAUNCHER',1,true) then
                assert(n<30,'Escape did not remove menubar launcher'); return
            end
            io.stderr:write('[PASS] centered launcher pixels, menubar center/width, prompt key input and Escape absence\n')
            return true
        end,
        function()
            if #notifications==0 then return true end
            local dump=awesome._clay_tree(s)
            assert(dump:find('offset -16,16 band 90',1,true))
            assert(dump:find('parent RIGHT_TOP own RIGHT_TOP',1,true))
            notification_boxes={}
            for x,y,w,h in dump:gmatch('\n    NOTIFICATION [^\n]- box (%d+),(%d+) (%d+)x(%d+)') do
                local box={x=tonumber(x),y=tonumber(y),width=tonumber(w),height=tonumber(h)}
                notification_boxes[#notification_boxes+1]=box
                assert(box.x==944 and box.width==320)
                example.pixel(box.x+2,box.y+2,'#ff0000')
            end
            assert(#notification_boxes==3)
            assert(notification_boxes[1].y==16)
            for i=2,3 do
                local prev=notification_boxes[i-1]
                assert(notification_boxes[i].y==prev.y+prev.height+8)
                example.pixel(prev.x+2,prev.y+prev.height+4,'#123456')
            end
            notifications[2]:destroy()
            return true
        end,
        function(n)
            if not notification_boxes then return true end
            local dump=awesome._clay_tree(s)
            if dump:find('Battery low',1,true) then assert(n<30,'dismissed notification still declared'); return end
            local count=0
            for x,y,w,h in dump:gmatch('\n    NOTIFICATION [^\n]- box (%d+),(%d+) (%d+)x(%d+)') do
                count=count+1
                assert(tonumber(y)==notification_boxes[count].y)
                example.pixel(tonumber(x)+2,tonumber(y)+2,'#ff0000')
            end
            assert(count==2)
            local old=notification_boxes[3]
            example.pixel(old.x+2,old.y+2,'#123456')
            notifications[1]:destroy(); notifications[3]:destroy()
            return true
        end,
        function(n)
            if not notification_boxes then return true end
            if awesome._clay_tree(s):find('NOTIFICATIONS',1,true) then
                assert(n<30,'empty stack is still declared'); return
            end
            io.stderr:write('[PASS] notification right-top inputs, solved stack pixels/gaps, dismissal reflow and empty-stack absence\n')
            return true
        end,
        function(n)
            if not tooltip then return true end
            local g=tooltip.wibox:geometry()
            local dump=awesome._clay_tree(s)
            assert(dump:find('parent BOTTOM_CENTER own TOP_CENTER pointer passthrough',1,true))
            assert(g.y==34, 'tooltip offset must be 6 below 28-pixel target')
            example.pixel(g.x+2,g.y+2,'#ff0000')
            tooltip.gaps=-20
            return true
        end,
        function(n)
            if not tooltip then return true end
            local g=tooltip.wibox:geometry()
            if g.y~=8 then assert(n<30,'tooltip input gap did not move it'); return end
            example.pixel(g.x+2,g.y+2,'#ff0000')
            awful.spawn {'./build-test/test-virtual-pointer-client','click',tostring(g.x+2),'12','1280','720','left'}
            return true
        end,
        function(n)
            if not tooltip then return true end
            if tooltip_clicks~=1 then assert(n<30,'tooltip intercepted real click'); return end
            assert(tooltip.visible, 'passthrough must retain hover underneath')
            awful.spawn {'./build-test/test-virtual-pointer-client','move','100','100','1280','720'}
            return true
        end,
        function(n)
            if not tooltip then return true end
            if tooltip.visible or awesome._clay_tree(s):find('  TOOLTIP ',1,true) then
                assert(n<30,'pointer leave did not remove tooltip'); return
            end
            io.stderr:write('[PASS] tooltip solved pixels, input gap, real pointer passthrough click and hover-leave absence\n')
            return true
        end,
        function()
            if popup then popup.visible=false end
            if tooltip then tooltip.hide() end
            for _, n in ipairs(notifications) do n:destroy() end
            if pid then awful.spawn({'kill','-9',tostring(pid)}) end
            os.remove(layer_report)
            if stretch_pid then awful.spawn({"kill","-9",tostring(stretch_pid)}) end
            os.remove(stretch_report)
            bar:remove()
            return true
        end,
    }
end
return M
