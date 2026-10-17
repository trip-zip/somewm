local policy = {}
local warned = setmetatable({}, {__mode = "k"})

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function words(value)
    if type(value) == "string" then return true end
    if not plain(value) then return false end
    local count = 0
    for key, word in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(word) ~= "string" then return false end
        count = count + 1
    end
    for i = 1, count do if rawget(value, i) == nil then return false end end
    return count > 0
end

function policy.widget(value)
    if not plain(value) then return false end
    for key, duration in pairs(value) do
        if type(key) ~= "string" or type(duration) ~= "number" then return false end
    end
    return true
end

function policy.client(value)
    if not plain(value) then return false end
    for key, setting in pairs(value) do
        if type(key) ~= "string" then return false end
        if type(setting) ~= "number" then
            if key ~= "appear" and key ~= "disappear" and key ~= "tag" then return false end
            if setting ~= false and not words(setting) then return false end
        end
    end
    return true
end

function policy.drawin(value)
    if not plain(value) then return false end
    for key, settings in pairs(value) do
        if key ~= "visible" or not plain(settings) then return false end
        for name, setting in pairs(settings) do
            if name == "duration" or name == "exit_duration" or name == "tag_duration" then
                if type(setting) ~= "number" then return false end
            elseif name == "enter" or name == "exit" or name == "tag_exit" or name == "properties" then
                if not words(setting) then return false end
            elseif name == "exit_order" then
                if type(setting) ~= "string" then return false end
            else
                return false
            end
        end
    end
    return true
end

-- Only validated policies reach this copy; nested values are effect lists or
-- the drawin's visibility settings, never config-owned objects.
function policy.copy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, setting in pairs(value) do copy[key] = policy.copy(setting) end
    return copy
end

function policy.warn(object)
    if warned[object] then return end
    warned[object] = true
    require("gears.debug").print_warning("wibox.clay: " .. tostring(object)
        .. " animation is not a policy; the value is preserved and supplies no animation policy")
end

function policy.prepare(object, value, kind)
    assert(value == nil or value == false or type(value) == "table", "animation must be a table or false")
    local foreign = type(value) == "table" and not policy[kind](value)
    if foreign then
        policy.warn(object)
        return value, true
    end
    return policy.copy(value), false
end

return policy
