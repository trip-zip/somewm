-- Public grid diagnostic retaining every example, reducer and golden assertion.
-- Behavioral checks run even when a tree representation differs.
local tidy = require('_clay_tidy')
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
        local function find(w,x,y)
            for _,hit in ipairs(state.popup:find_widgets(x,y)) do
                if hit.widget==w then return hit end
            end
        end
        local b=find(state.grid,0,0)
        if case.name=='tidy-grid-empty' then
            assert(not b,'empty unallocated grid must be omitted')
            io.stderr:write('[INPUT] '..case.name..' empty=true no_grid_target=true\n')
            return true
        end
        assert(b)
        if case.name=='tidy-grid-wrapped-text' then
            -- Half of 90 less the gap is 42.5: the boxes round to 43 and 42,
            -- and each row is as tall as its tallest text.
            local dump=awesome._clay_tree(screen[1])
            local heights={}
            for i,w in ipairs(state.widgets) do
                local quoted='"'..w.text:gsub('%p','%%%0')..'"'
                heights[i]=tonumber(dump:match(quoted..' font=%d+ box %-?%d+,%-?%d+ %d+x(%d+)'))
            end
            local rows={math.max(heights[1],heights[2]),math.max(heights[3],heights[4])}
            assert(b.width==90 and b.height==rows[1]+5+rows[2])
            for i,w in ipairs(state.widgets) do
                local x,y=((i-1)%2)*48,i>2 and rows[1]+5 or 0
                local box=assert(find(w,b.x+x+1,b.y+y+1))
                assert(box.x==b.x+x and box.y==b.y+y)
                assert(box.width==(i%2==1 and 43 or 42) and box.height==rows[i>2 and 2 or 1])
            end
        elseif case.name=='tidy-grid-nested' then
            for i,inner in ipairs(state.grid:get_children()) do
                local size=i==1 and 10 or 20
                local ib=assert(find(inner,b.x+(i==1 and 0 or 30)+1,b.y+1))
                assert(ib.x==b.x+(i==1 and 0 or 30) and ib.y==b.y)
                assert(ib.width==size*2+5 and ib.height==45)
                for j,w in ipairs(inner:get_children()) do
                    local x,y=ib.x+((j-1)%2)*(size+5),ib.y+math.floor((j-1)/2)*(size+5)
                    local box=assert(find(w,x+1,y+1))
                    assert(box.x==x and box.y==y and box.width==size and box.height==size)
                end
            end
        end
        if n==1 then
            state.presses=0;state.releases=0
            state.grid:connect_signal('button::press',function(w,x,y,button,_,area)
                assert(w==state.grid and area.widget==w and area.occurrence==b.occurrence)
                assert(x==2 and y==2 and button==1)
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
