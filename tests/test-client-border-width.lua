---------------------------------------------------------------------------
-- Test: the client's border_width is the only border the frame draws
--
-- A client whose rules set no border_width has none: border_width reads 0
-- and its CLIENT line has no pad. Setting 3 pads the frame by 3 and draws a
-- BORDER command at the frame box. Fullscreen draws none, and leaving
-- fullscreen restores the client's own 3, not a theme value.
--
-- Run: make test-one TEST=tests/test-client-border-width.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local utils = require("_utils")

local TEST_CLIENT = utils.binary_or_skip("./build-test/test-transient-client")
if not TEST_CLIENT then
    return
end

local s = screen[1]
local c

local function client_line(tree)
    for line in tree:gmatch("[^\n]+") do
        if line:find("CLIENT " .. c.class .. " ", 1, true) then return line end
    end
end

local function border_line(tree)
    for line in tree:gmatch("[^\n]+") do
        if line:find("BORDER", 1, true) and line:find(c.class, 1, true) then return line end
    end
end

-- Waits until the CLIENT line has the padding of bw (none for 0) and the
-- client's geometry is the solved one.
local function expect_pad(bw)
    return function(count)
        local tree = awesome._clay_tree(s)
        local line = client_line(tree)
        local pad = line and line:match(" pad (%d+,%d+,%d+,%d+)")
        local want = bw > 0 and string.format("%d,%d,%d,%d", bw, bw, bw, bw) or nil
        if not (line and pad == want and c:_clay_geometry_is_solved()) then
            assert(count < 30, string.format("expected pad %s: %s\n%s",
                tostring(want), tostring(line), tree))
            return nil
        end
        local border = border_line(tree)
        if bw > 0 then
            local g = c:geometry()
            local box = string.format("box %d,%d %dx%d", g.x - s.geometry.x, g.y - s.geometry.y,
                g.width + 2 * bw, g.height + 2 * bw)
            assert(border and border:find(box, 1, true),
                "no BORDER at the frame box " .. box .. "\n" .. tree)
        else
            assert(not border, "a client with no border draws one: " .. tostring(border))
        end
        io.stderr:write(string.format("[PASS] pad %s: %s\n", tostring(want), line))
        return true
    end
end

runner.run_steps({
    function(count)
        if count == 1 then
            s.selected_tag.layout = awful.layout.suit.tile
            awful.spawn(TEST_CLIENT)
        end
        c = utils.find_client_by_class("transient_test_parent")
        if not c then
            assert(count < 30, "client did not map")
            return nil
        end
        assert(not c.floating, "the client must be tiled")
        assert(c.border_width == 0,
            "a client whose rules set no border_width has " .. c.border_width)
        return true
    end,
    expect_pad(0),
    function()
        c.border_width = 3
        return true
    end,
    expect_pad(3),
    function()
        c.fullscreen = true
        return true
    end,
    function(count)
        local line = client_line(awesome._clay_tree(s))
        if not (line and line:find("w=grow h=grow", 1, true) and line:find("band 40", 1, true)) then
            assert(count < 30, "fullscreen never declared: " .. tostring(line))
            return nil
        end
        assert(not line:find(" pad ", 1, true), "fullscreen draws a border: " .. line)
        io.stderr:write("[PASS] fullscreen has no pad: " .. line .. "\n")
        return true
    end,
    function()
        c.fullscreen = false
        return true
    end,
    expect_pad(3),
    function()
        c:kill()
        return true
    end,
}, { kill_clients = false })
