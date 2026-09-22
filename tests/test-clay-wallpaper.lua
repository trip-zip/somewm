---------------------------------------------------------------------------
-- Test: the wallpaper is a Clay node
--
-- root.wallpaper(pattern) paints one surface over the whole output layout;
-- each output's OUTPUT element carries its crop as its image, so the
-- realized list opens with one IMAGE node named for the output, sized to
-- it, and the scene agrees with the tree. With no wallpaper the element
-- paints the root colour instead, a RECTANGLE. Setting another wallpaper
-- replaces the image's pixels rather than adding a node.
--
-- Run: make test-one TEST=tests/test-clay-wallpaper.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local gcolor = require("gears.color")

local s = screen[1]

local function lines()
    local out = {}
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        out[#out + 1] = line
    end
    return out
end

-- The realized IMAGE nodes the output element painted: the wallpaper.
local function wallpaper_lines()
    local out = {}
    for _, line in ipairs(lines()) do
        if line:find(" IMAGE ", 1, true) and line:find(" output ", 1, true) then
            out[#out + 1] = line
        end
    end
    return out
end

local function assert_agrees()
    for _, line in ipairs(lines()) do
        assert(not line:find("[tree!=scene]", 1, true),
            "the scene disagrees with the tree: " .. line)
    end
end

local steps = {
    -- No wallpaper set: no leaf for it.
    function(count)
        if count == 1 then
            return nil
        end
        assert(#wallpaper_lines() == 0, "a wallpaper leaf with no wallpaper")
        io.stderr:write("[PASS] no wallpaper, no leaf\n")
        return true
    end,

    -- One wallpaper: one image leaf, the output's size, first in the band.
    function(count)
        if count == 1 then
            root.wallpaper(gcolor("#336699"))
            return nil
        end
        local found = wallpaper_lines()
        if #found == 0 then
            return nil
        end
        local geo = s.geometry
        local box = string.format("box 0,0 %dx%d", geo.width, geo.height)

        assert(#found == 1, "more than one wallpaper leaf: " .. #found)
        assert(found[1]:find("IMAGE", 1, true), "not an image leaf: " .. found[1])
        assert(found[1]:find(box, 1, true), "not the output's box: " .. found[1])
        -- The first realized node is the bottom of the draw order.
        local first
        for i, line in ipairs(lines()) do
            if line == "  realized:" then
                first = lines()[i + 1]
                break
            end
        end
        assert(first == found[1], "the wallpaper is not at the bottom: "
            .. tostring(first))
        assert_agrees()
        io.stderr:write("[PASS] " .. found[1] .. "\n")
        return true
    end,

    -- Another wallpaper replaces the pixels, not the leaf.
    function(count)
        if count == 1 then
            root.wallpaper(gcolor("#996633"))
            return nil
        end
        if count < 5 then
            return nil
        end
        assert(#wallpaper_lines() == 1, "the second wallpaper added a leaf")
        assert(root.wallpaper() ~= nil, "root.wallpaper() answers nothing")
        assert_agrees()
        io.stderr:write("[PASS] a second wallpaper keeps one leaf\n")
        return true
    end,
}

runner.run_steps(steps)
