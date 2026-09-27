local M = {}

-- 32-bit arithmetic without a bit library, which only LuaJIT ships:
-- modulo for wraparound, multiplication and floor division for shifts,
-- and a loop for xor. math.floor keeps Lua 5.3 on integers.
local function u32(x) return x % 0x100000000 end
local function bxor(a, b)
    local result, place = 0, 1
    while a > 0 or b > 0 do
        local x, y = a % 2, b % 2
        if x ~= y then result = result + place end
        a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
    end
    return result
end

-- Clay's string ID hash, used to address its private inspector scroll pane.
function M.id(text)
    local hash = 0
    for i = 1, #text do
        hash = u32(hash + text:byte(i))
        hash = u32(hash + u32(hash * 1024))
        hash = bxor(hash, math.floor(hash / 64))
    end
    hash = u32(hash + u32(hash * 8))
    hash = bxor(hash, math.floor(hash / 2048))
    hash = u32(hash + u32(hash * 32768) + 1)
    return hash
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
