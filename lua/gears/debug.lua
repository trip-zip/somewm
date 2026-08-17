---------------------------------------------------------------------------
-- Utility functions to make development easier.
--
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @utillib gears.debug
---------------------------------------------------------------------------

local tostring = tostring
local print = print
local type = type
local pairs = pairs

local debug = {}

--- Given a table (or any other data) return a string that contains its
-- tag, value and type. If data is a table then recursively call `dump_raw`
-- on each of its values.
-- @param data Value to inspect.
-- @param shift Spaces to indent lines with.
-- @param tag The name of the value.
-- @tparam[opt=10] int depth Depth of recursion.
-- @return a string which contains tag, value, value type and table key/value
-- pairs if data is a table.
local function dump_raw(data, shift, tag, depth)
    depth = depth == nil and 10 or depth or 0
    local result = ""

    if tag then
        result = result .. tostring(tag) .. " : "
    end

    if type(data) == "table" and depth > 0 then
        shift = (shift or "") .. "  "
        result = result .. tostring(data)
        for k, v in pairs(data) do
            result = result .. "\n" .. shift .. dump_raw(v, shift, k, depth - 1)
        end
    else
        result = result .. tostring(data) .. " (" .. type(data) .. ")"
        if depth == 0 and type(data) == "table" then
            result = result .. " […]"
        end
    end

    return result
end

--- Inspect the value in data.
-- @param data Value to inspect.
-- @param tag The name of the value.
-- @tparam[opt] int depth Depth of recursion.
-- @treturn string A string that contains the expanded value of data.
-- @staticfct gears.debug.dump_return
function debug.dump_return(data, tag, depth)
    return dump_raw(data, nil, tag, depth)
end

--- Print the table (or any other value) to the console.
-- @param data Table to print.
-- @param tag The name of the table.
-- @tparam[opt] int depth Depth of recursion.
-- @staticfct gears.debug.dump
-- @noreturn
function debug.dump(data, tag, depth)
    print(debug.dump_return(data, tag, depth))
end

--- Print an warning message
-- @tparam string message The warning message to print.
-- @staticfct gears.debug.print_warning
-- @noreturn
function debug.print_warning(message)
    io.stderr:write(os.date("%Y-%m-%d %T W: awesome: ") .. tostring(message) .. "\n")
end

--- Print an error message
-- @tparam string message The error message to print.
-- @staticfct gears.debug.print_error
-- @noreturn
function debug.print_error(message)
    io.stderr:write(os.date("%Y-%m-%d %T E: awesome: ") .. tostring(message) .. "\n")
end

local displayed_deprecations = {}

--- Display a deprecation notice, but only once per traceback.
--
-- @param[opt] see The message to a new method / function to use.
-- @tparam table args Extra arguments
-- @tparam boolean args.raw Print the message as-is without the automatic context
-- @staticfct gears.debug.deprecate
-- @noreturn
function debug.deprecate(see, args)
    args = args or {}
    local tb = _G.debug.traceback()
    if displayed_deprecations[tb] then
        return
    end
    displayed_deprecations[tb] = true

    -- Get function name/desc from caller.
    local info = _G.debug.getinfo(2, "n")
    local funcname = info.name or "?"
    local msg = "awful: function " .. funcname .. " is deprecated"
    if see then
        if args.raw then
            msg = see
        elseif string.sub(see, 1, 3) == 'Use' then
            msg = msg .. ". " .. see
        else
            msg = msg .. ", see " .. see
        end
    end
    debug.print_warning(msg .. ".\n" .. tb)
end

return debug

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
