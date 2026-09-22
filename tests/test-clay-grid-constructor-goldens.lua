-- Public grid diagnostic retaining every example, reducer and golden assertion.
-- Behavioral checks run even when a tree representation differs.
local tidy = require('_clay_tidy')
local solver=dofile('tests/_grid_solver.lua')
local check=require('_clay_grid_presentation')
local pointer=assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))
local original_run = tidy.run
local cases
tidy.run = function(value) cases=value end
require('test-clay-tidy-grid')
tidy.run = original_run
local example = require('_clay_example')
local checks = example.batch()
local steps, state, previous, behavior_failures = {}, nil, nil, {}
for _, case in ipairs(cases) do
    steps[#steps+1] = function()
        require('beautiful').font = 'monospace 10'
        state = case.create()
        awesome._test_redeclare()
        check(state.popup._drawable)
        previous = nil
        return true
    end
    steps[#steps+1] = function(n)
        local dump = awesome._clay_tree(screen[1])
        if n<3 or dump~=previous then
            previous=dump
            assert(n<30,case.name..' did not settle')
            return
        end
        checks.check(case.name,dump)
        -- Exercise the original pixel/lookup checks even if shape differs.
        local ok,reason=true,'no behavioral assertion in original case'
        if case.verify then ok,reason=pcall(case.verify,state,dump) end
        local result=(ok and 'PASS' or 'FAIL')..' '..tostring(reason or '')
        io.stderr:write('[BEHAVIOR] ',case.name,' ',result,'\n')
        local dir=os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
        if dir then
            local f=assert(io.open(dir..'/'..case.name..'.behavior','w'))
            f:write(result,'\n'); f:close()
        end
        if not ok then behavior_failures[#behavior_failures+1]=case.name end
        return true
    end
    steps[#steps+1] = function(n)
        local found=solver.find(state.popup._drawable._clay_tree,state.grid)
        if case.name=='tidy-grid-empty' then
            assert(#found==0,'empty unallocated grid must be omitted')
            for _,hit in ipairs(state.popup:find_widgets(0,0)) do assert(hit.widget~=state.grid) end
            io.stderr:write('[INPUT] '..case.name..' empty=true no_grid_target=true\n')
            return true
        end
        assert(#found==1)
        local b=found[1].box
        if case.name=='tidy-grid-wrapped-text' then
            assert(b.width==90 and b.height==65)
            for i,w in ipairs(state.widgets) do
                local box=solver.find(state.popup._drawable._clay_tree,w)[1].box
                assert(box.x==b.x+((i-1)%2)*47 and box.y==b.y+(i>2 and 45 or 0))
                assert(box.width==42 and box.height==(i>2 and 20 or 40))
                assert(box.height>=w:get_height_for_width(box.width,screen[1]))
            end
        elseif case.name=='tidy-grid-nested' then
            for i,inner in ipairs(state.grid:get_children()) do
                local size=i==1 and 10 or 20
                local ib=solver.find(state.popup._drawable._clay_tree,inner)[1].box
                assert(ib.x==b.x+(i==1 and 0 or 30) and ib.y==b.y)
                assert(ib.width==size*2+5 and ib.height==45)
                for j,w in ipairs(inner:get_children()) do
                    local box=solver.find(state.popup._drawable._clay_tree,w)[1].box
                    assert(box.x==ib.x+((j-1)%2)*(size+5) and box.y==ib.y+math.floor((j-1)/2)*(size+5))
                    assert(box.width==size and box.height==size)
                end
            end
        end
        if n==1 then
            state.presses=0;state.releases=0
            state.grid:connect_signal('button::press',function(w,x,y,button,_,area)
                assert(w==state.grid and area.widget==w and area.occurrence==found[1].binding.id)
                assert(x==2 and y==2 and button==1)
                check(state.popup._drawable)
                state.presses=state.presses+1
            end)
            state.grid:connect_signal('button::release',function() state.releases=state.releases+1 end)
            require('awful').spawn{pointer,'click',tostring(state.popup.x+b.x+2),tostring(state.popup.y+b.y+2),'1280','720','left'}
        end
        assert(n<30,case.name..': real pointer was not delivered')
        if state.presses~=1 or state.releases~=1 then return end
        io.stderr:write('[INPUT] '..case.name..' press=1 release=1 original_occurrence=true local=2,2\n')
        return true
    end
    steps[#steps+1] = function()
        state.popup.visible=false
        if state.cleanup then state.cleanup() end
        state=nil
        return true
    end
end
steps[#steps+1] = function()
    io.stderr:write('[BEHAVIOR FAILURES] ',table.concat(behavior_failures,', '),'\n')
    checks.finish()
    assert(#behavior_failures==0,'grid behavior differs from the accepted contract')
    return true
end
require('_runner').run_steps(steps)
