-- Assert presentation at the frame boundary, not during helper readback.
local clay=require('wibox.clay')
local observed={}
local publish=clay._publish
clay._publish=function(self,...)
    publish(self,...)
    observed[self]=true
end
local function check(self)
    local count=0
    local function walk(node)
        count=count+1
        assert(self._clay_index[count]==node,'published occurrence index differs from tree')
        for _,binding in clay.bindings(node) do
            assert(binding.element==node,'binding points at another generation')
            if binding.grid_state then
                assert(binding.grid_state.settled,'measurement layout reached presentation')
            end
        end
        for _,child in ipairs(node.children or {}) do walk(child) end
    end
    walk(self._clay_tree)
    assert(count==#self._clay_index)
end
local frame=awesome._test_redeclare
awesome._test_redeclare=function(...)
    observed={}
    local result=frame(...)
    local count=0
    for self in pairs(observed) do check(self);count=count+1 end
    io.stderr:write(string.format('[PRESENT42] published_drawables=%d all_settled=true indices=true\n',count))
    return result
end
return check
