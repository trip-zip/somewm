---------------------------------------------------------------------------
--- Test: the tree == scene assertion, both directions.
---
---   1. C assert (clay_apply_all -> clay_assert_node): a clean Clay-managed
---      tile arrange applies exactly the box it solved, so under
---      SOMEWM_TREE_ASSERT=abort the compositor must NOT abort. Reaching the
---      assertions below (the compositor stayed up through the arrange) is the
---      check; under the default `warn` mode it simply cannot abort.
---
---   2. Lua complement (`clay.tree assert=true`): reports live scene objects
---      the screen paints that no tree node declared. A tiled client is a tree
---      node, so it is never absent. A standalone visible drawin (not a wibar,
---      so not part of the screen solve) is reported absent.
---
--- Run under abort to exercise direction 1:
---   SOMEWM_TREE_ASSERT=abort make test-one TEST=tests/test-clay-tree-assert.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")
local wibox = require("wibox")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local clay = require("awful.layout.clay")
local ipc = require("awful.ipc")

local s = screen.primary
local tag = s.tags[1]
local popup

local steps = {
    -- Clay-managed tile + a tiled client with a real border.
    function(count)
        if count == 1 then
            tag:view_only()
            tag.layout = clay.tile
            tag.gap = 0
            test_client("tree_assert")
            return nil
        end
        local c = utils.find_client_by_class("tree_assert")
        if c then c.border_width = 4; return true end
        if count >= 20 then error("client never appeared") end
        return nil
    end,

    -- Arrange (applies the solve; under abort this would abort on any
    -- divergence). Wait until the delayed arrange settles and the tiled client
    -- is actually a tree node, then the completeness check must not report it
    -- absent. Keying on the client appearing in the tree (not just any
    -- response) avoids asserting against a pre-arrange tree under load.
    function(count)
        if count == 1 then awful.layout.arrange(s); return nil end
        local tree = ipc.dispatch("clay tree", -1)
        if type(tree) ~= "string" or not tree:find("client.tree_assert", 1, true) then
            if count >= 15 then error("tiled client never appeared in the tree") end
            return nil
        end
        local resp = ipc.dispatch("clay tree assert=true", -1)
        io.stderr:write("[TEST] clean assert:\n" .. resp .. "\n")
        assert(resp:match("^OK\n"), "assert command should return OK")
        assert(not resp:find("absent  client", 1, true),
            "a tiled client in the tree must never be reported absent")
        io.stderr:write("[TEST] PASS: clean tile, client present, no abort\n")
        return true
    end,

    -- A standalone visible drawin is not part of the screen solve, so the Lua
    -- complement must now report a drawin absent from the tree.
    function(count)
        if count == 1 then
            local g = s.geometry
            popup = wibox {
                x = g.x + 10, y = g.y + 10,
                width = 100, height = 40,
                visible = true,
                ontop = true,
            }
            return nil
        end
        local resp = ipc.dispatch("clay tree assert=true", -1)
        if type(resp) == "string" and resp:find("absent from tree", 1, true) then
            io.stderr:write("[TEST] desync assert:\n" .. resp .. "\n")
            assert(resp:find("absent  drawin", 1, true),
                "the off-tree drawin should be reported absent")
            io.stderr:write("[TEST] PASS: off-tree drawin reported as desync\n")
            return true
        end
        if count >= 15 then error("off-tree drawin was never reported absent") end
        return nil
    end,

    -- Cleanup.
    function(count)
        if count == 1 then
            if popup then popup.visible = false; popup = nil end
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then
            for _, pid in ipairs(test_client.get_spawned_pids()) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
