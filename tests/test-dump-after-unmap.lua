---------------------------------------------------------------------------
-- Test: a tree dump between a client's unmap and the next frame
--
-- The unmap destroys the client's scene tree in the same dispatch that emits
-- request::unmanage; a delayed call runs on the next refresh, before the
-- frame that drops the client's leaf. A dump there must report the leaf
-- without a node, and the frame after must have no leaf at all.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")
local gears = require("gears")
local utils = require("_utils")

local binary = assert(utils.binary_or_skip("./build-test/test-transient-client"))

local APP_ID = "dump_after_unmap"

local function frames(dump)
    return tonumber(dump:match(" frames (%d+) "))
end

local function realized_line(dump, id)
    return dump:match("\n(  " .. id .. " CUSTOM[^\n]*)")
end

runner.run_async(function()
    local pid = awful.spawn { binary, APP_ID }
    local c = assert(async.wait_for_client(APP_ID, 5), "client did not map")
    local s = c.screen

    local id
    assert(async.wait_for_condition(function()
        id = awesome._clay_tree(s):match("\n  (%x+) CUSTOM[^\n]* client " .. APP_ID)
        return id ~= nil
    end, 2, .02), "client leaf was not realized")

    local after
    c:connect_signal("request::unmanage", function()
        gears.timer.delayed_call(function()
            after = awesome._clay_tree(s)
        end)
    end)
    awesome.kill(pid, 9)
    assert(async.wait_for_condition(function() return after ~= nil end, 5, .02),
        "no dump after unmanage")

    local line = realized_line(after, id)
    assert(line == nil or line:find(" no-node", 1, true), after)

    local next_dump
    assert(async.wait_for_condition(function()
        next_dump = awesome._clay_tree(s)
        return frames(next_dump) > frames(after)
    end, 2, .02), "no frame after unmanage")
    assert(realized_line(next_dump, id) == nil, next_dump)

    io.stderr:write("[PASS] a dump after an unmap reports the dead client without a node\n")
    runner.done()
end)
