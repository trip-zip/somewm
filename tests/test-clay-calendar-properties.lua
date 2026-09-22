-- Calendar setters rebuild public grid membership and retain coherent presentation.
local runner=require('_runner')
local async=require('_async')
local wibox=require('wibox')
local awful=require('awful')
local example=require('_clay_example')
local check=require('_clay_grid_presentation')
local solver=dofile('tests/clay/grid-helper.lua')
runner.run_async(function()
    for _,kind in ipairs{'month','year'} do
        local cal=wibox.widget.calendar[kind](nil,'monospace 10')
        cal.spacing=3;cal.week_numbers=true;cal.date={year=2024,month=2,day=29}
        local host=awful.popup{screen=screen[1],x=0,y=0,visible=true,widget=cal,bg='#204080',maximum_width=1100}
        local function present(label,border_pixel)
            awesome._test_redeclare();check(host._drawable)
            local grids,texts={},{}
            local function walk(w)
                if w._private.widgets and w._private.num_cols then grids[#grids+1]=w end
                if w.set_text then texts[#texts+1]=w end
                for _,child in ipairs(w._private.container and {w._private.container} or w:get_children()) do walk(child) end
            end
            walk(cal)
            assert(#grids==(kind=='year' and 13 or 1))
            for i,g in ipairs(grids) do
                local found=solver.find(host._drawable._clay_tree,g)
                assert(#found==1,label..': missing original calendar grid')
                assert(found[1].binding.grid_state.settled)
                if kind=='month' or i>1 then
                    assert(g.column_count==(cal.week_numbers and 8 or 7))
                end
            end
            for _,w in ipairs(texts) do
                assert(#solver.find(host._drawable._clay_tree,w)==1,label..': missing original text')
            end
            if border_pixel then
                local b=solver.find(host._drawable._clay_tree,grids[1])[1].box
                example.pixel(host.x+b.x,host.y+b.y,border_pixel)
            end
            example.save(kind..'-'..label,awesome._clay_tree(screen[1]))
            assert(awesome._test_redeclare()==0,label..': unstable presentation')
            io.stderr:write('[CALENDAR] '..kind..' '..label..' public grids='..#grids..' original_texts='..#texts..' PASS\n')
            return host.width,host.height
        end
        local width,height=present('leap-day')
        cal.start_sunday=true;present('sunday')
        cal.start_sunday=false;present('monday-restored')
        cal.long_weekdays=true;present('long-weekdays')
        cal.long_weekdays=false;present('short-weekdays-restored')
        cal.week_numbers=false;present('no-week-numbers')
        cal.week_numbers=true;present('week-numbers-restored')
        cal.spacing=5;present('spacing-grow')
        cal.spacing=3;present('spacing-restored')
        cal.date={year=2026,month=9,day=16};present('date-switch')
        cal.date={year=2024,month=2,day=29};present('leap-day-restored')
        cal.flex_height=true;present('flex-height')
        cal.flex_height=false;present('flex-height-restored')
        cal.fn_embed=function(w,flag)
            if flag=='monthheader' or flag=='header' or flag=='yearheader' then
                return wibox.container.margin(w,2,2,2,2)
            end
            return w
        end
        present('embedded-headers')
        cal.fn_embed=function(w) return w end
        local rw,rh=present('embedding-restored');assert(rw==width and rh==height)
        if kind=='month' then
            cal.border_color='#ffffff';cal.border_width=1;present('borders','#ffffff')
            cal.border_color={inner='#ff0000',outer='#00ff00'};present('border-colors','#00ff00')
            cal.border_width=0;present('borders-removed')
        end
        async.sleep(.25);assert(awesome._test_redeclare()==0)
        host.visible=false
    end
    runner.done()
end)
