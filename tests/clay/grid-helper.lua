-- Actual compiler -> untouched upstream solver -> production Lua publication.
-- The C fixture's TSV interface marshals ordinary declarations only.
local clay = require('wibox.clay')
local M = {}
local binary, temporary
function M.start()
    binary = os.getenv('GRID_HELPER_SOLVER')
    if not binary then
        temporary = os.tmpname()
        binary = temporary
        assert(os.execute('cc -std=c99 -isystem tests/clay/vendor -O2 tests/clay/grid-constructor.c -lm -o '..binary))
    end
end
function M.stop()
    if temporary then os.remove(temporary) end
end
function M.solve(tree, label)
    local path = os.tmpname()
    local out = assert(io.open(path, 'w'))
    local nodes, indices = {}, {}
    local function axis(n, k)
        local v = n[k] or 'fit'
        return (type(v)=='table' and 'p' or type(v)=='number' and 'n' or v=='grow' and 'g' or 'f')
            ..' '..(type(v)=='table' and v.percent or type(v)=='number' and v or 0)
            ..' '..(n[k..'min'] or 0)..' '..(n[k..'max'] or 0)
    end
    local function walk(n, parent)
        local id = #nodes
        nodes[id+1] = n
        indices[n]=id
        assert(not n.grid and not n.ceil_grow and not n.size_contain)
        assert(not n.text, 'actual text requires the compositor/font bridge')
        out:write(parent,' node',id,' ',n.dir=='y' and 1 or 0,' ',n.gap or 0,
            ' ',axis(n,'w'),' ',axis(n,'h'),' ',n.bg and 1 or 0,
            ' ',n.float and 1 or 0,' ',n._attach and assert(indices[n._attach]) or -1,
            ' ',n.x or 0,' ',n.y or 0,' ',n.parent or 0,' ',n.own or 0,
            ' ',n.pad and n.pad[1] or 0,' ',n.pad and n.pad[2] or 0,
            ' ',n.pad and n.pad[3] or 0,' ',n.pad and n.pad[4] or 0,'\n')
        for _, child in ipairs(n.children or {}) do walk(child,id) end
    end
    walk(tree,-1); out:close()
    local process = assert(io.popen(binary..' '..path..' 2>&1'))
    local result = process:read('*a')
    local ok = process:close(); assert(ok,result)
    local dir = os.getenv('GRID_CONSTRUCTOR_EVIDENCE')
    if dir and label then
        local f = assert(io.open(dir..'/'..label..'.tsv','w'))
        local input = assert(io.open(path)); f:write(input:read('*a')); input:close(); f:close()
        f = assert(io.open(dir..'/'..label..'.boxes','w')); f:write(result); f:close()
    end
    os.remove(path)
    local boxes = {}
    for id,x,y,w,h in result:gmatch('node(%d+)[^\n]-box=([%d.-]+),([%d.-]+) ([%d.-]+)x([%d.-]+)') do
        local node = nodes[tonumber(id)+1]
        if not node.spacer then
            x,y,w,h = tonumber(x),tonumber(y),tonumber(w),tonumber(h)
            local function round(v) return math.floor(v+.5) end
            boxes[#boxes+1] = {x=round(x),y=round(y),width=round(x+w)-round(x),height=round(y+h)-round(y)}
        end
    end
    return boxes
end
function M.find(tree, widget)
    local result = {}
    local function walk(n)
        for _, binding in clay.bindings(n) do
            if binding.widget == widget then result[#result+1] = {node=n,binding=binding,box=n.box} end
        end
        for _, child in ipairs(n.children or {}) do walk(child) end
    end
    walk(tree)
    return result
end
return M
