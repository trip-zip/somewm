local bit = require('bit')
local M = {}

-- Clay's string ID hash, used to address its private inspector scroll pane.
function M.id(text)
    local hash = 0
    for i = 1, #text do
        hash = bit.tobit(hash + text:byte(i))
        hash = bit.tobit(hash + bit.lshift(hash, 10))
        hash = bit.bxor(hash, bit.rshift(hash, 6))
    end
    hash = bit.tobit(hash + bit.lshift(hash, 3))
    hash = bit.bxor(hash, bit.rshift(hash, 11))
    hash = bit.tobit(hash + bit.lshift(hash, 15) + 1)
    return hash < 0 and hash + 4294967296 or hash
end

function M.check(s)
    local dump = awesome._clay_tree(s)
    local elements, capacity, map = dump:match('elements (%d+)/(%d+) map (%d+)')
    assert(elements, dump)
    assert(tonumber(elements) < tonumber(capacity) and tonumber(map) < tonumber(capacity), dump)
    assert(not dump:find('Clay Error', 1, true), dump)
    assert(not dump:find('[tree!=scene]', 1, true), dump)
    return dump, tonumber(elements), tonumber(map)
end

function M.count(tree)
    local count = 1
    for _, child in ipairs(tree.children or {}) do count = count + M.count(child) end
    return count
end
return M
