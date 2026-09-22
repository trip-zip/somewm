---------------------------------------------------------------------------
-- Clay tree goldens: the declared tree's shape, compared to a file.
--
-- shape() reduces a dump from awesome._clay_tree(screen) to what an example
-- in the board's tree-examples doc states: the root counts, then one line per
-- element in declaration order with its role, object, sizing types and fixed
-- numbers, source words, flow, attachment target and band, and the widget
-- nodes under each widget tree. Solved boxes, offsets, element ids, host
-- derived floors and ceilings, node counts and timings are dropped: they
-- depend on the output size or the frame, not on the shape.
--
-- check(name, dump) compares against tests/goldens/<name>.txt line by line
-- and fails on the first difference. SOMEWM_GOLDEN=record writes the file
-- instead. A golden is written by hand from the example before the code that
-- produces it exists; recording is for capturing a shape that is already
-- accepted.
---------------------------------------------------------------------------
local golden = {}

function golden.shape(dump)
    local out = {}
    local keep = false
    for line in dump:gmatch("[^\n]+") do
        if line:match("^output ") then
            keep = false
            out[#out + 1] = line:match("^output (%S+)") and "output" or line
        elseif line:match("^  roots ") then
            keep = true
            out[#out + 1] = line
        elseif line == "  realized:" then
            keep = false
        elseif keep and not line:match("^  commands ") then
            -- a widget node: drop the element id, keep the indentation
            line = line:gsub("^    %x%x%x%x%x%x%x%x ", "    ")
            line = line:gsub(" target %x+ parent %S+ own %S+ pointer %S+", "")
            line = line:gsub(" box %-?%d+,%-?%d+ %d+x%d+", "")
            line = line:gsub(" box %-$", "")
            line = line:gsub(" offset %-?[%d.]+,%-?[%d.]+", "")
            line = line:gsub("(screen %d+) %d+x%d+[%+%-]%d+[%+%-]%d+", "%1")
            line = line:gsub(" converted: %d+ nodes, %d+ images", " converted")
            line = line:gsub(", radius [%d.]+", "")
            line = line:gsub(">=[%d.]+", ""):gsub("<=[%d.]+", "")
            out[#out + 1] = line
        end
    end
    return table.concat(out, "\n") .. "\n"
end

local function path(name)
    return "tests/goldens/" .. name .. ".txt"
end

function golden.check(name, dump)
    local shape = golden.shape(dump)
    if os.getenv("SOMEWM_GOLDEN") == "record" then
        local f = assert(io.open(path(name), "w"))
        f:write(shape)
        f:close()
        io.stderr:write("[GOLDEN] recorded " .. path(name) .. "\n")
        return
    end
    local f = io.open(path(name), "r")
    assert(f, "no golden at " .. path(name) .. "; write it from the example")
    local want = f:read("*a")
    f:close()
    local want_lines, have_lines = {}, {}
    for l in want:gmatch("[^\n]*\n") do want_lines[#want_lines + 1] = l:sub(1, -2) end
    for l in shape:gmatch("[^\n]*\n") do have_lines[#have_lines + 1] = l:sub(1, -2) end
    for i = 1, math.max(#want_lines, #have_lines) do
        if want_lines[i] ~= have_lines[i] then
            error(string.format("%s differs at line %d\n  want: %s\n  have: %s\n--- have, whole:\n%s",
                path(name), i, tostring(want_lines[i]), tostring(have_lines[i]), shape))
        end
    end
    io.stderr:write("[GOLDEN] " .. name .. " matches, " .. #want_lines .. " lines\n")
end

return golden
