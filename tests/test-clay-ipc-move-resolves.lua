---------------------------------------------------------------------------
--- Test: an IPC move of a floating client auto-re-solves the screen (Wiring).
---
--- client.move goes through c:geometry(), which emits property::geometry; that
--- is now wired to the unconditional arrange (the floating-skip was dropped for
--- geometry), so the screen re-solves with no explicit awful.layout.arrange call.
--- The merged tile solve reflects the floater at the box the IPC move set. Driven
--- in-process via ipc.dispatch so the real IPC handler runs (find_client_by_id ->
--- c:geometry). One tiled client fills the workarea so tree==scene holds under
--- abort; the floater is reflected at its box (a no-op resize).
---
---   SOMEWM_TREE_ASSERT=abort make test-one TEST=tests/test-clay-ipc-move-resolves.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local clay = require("awful.layout.clay")
local ipc = require("awful.ipc")

local function counts() return _somewm_clay.get_solve_counts() end

local s = screen.primary
local tag = s.tags[1]
local c_tiled, c_float

local steps = {
    -- Clay-managed tile so the re-solve is a single merged solve.
    function()
        tag:view_only()
        tag.gap = 0
        tag.layout = clay.tile
        return true
    end,

    -- One tiled client keeps the tile merging; one floats and will be IPC-moved.
    function(count)
        if count == 1 then
            test_client("ipcmove_tiled")
            test_client("ipcmove_float")
        end
        c_tiled = utils.find_client_by_class("ipcmove_tiled")
        c_float = utils.find_client_by_class("ipcmove_float")
        return (c_tiled and c_float) and true or nil
    end,

    -- Float it at a known box and let the arrange settle.
    function(count)
        if count == 1 then
            c_float.floating = true
            c_float:geometry {
                x = s.geometry.x + 100,
                y = s.geometry.y + 80,
                width = 200, height = 150,
            }
            return nil
        end
        if not _somewm_clay.is_stale(s) then return true end
        if count >= 15 then error("float setup never drained") end
        return nil
    end,

    -- IPC-move it; the screen must auto-re-solve with no explicit arrange.
    function(count)
        if count == 1 then
            _somewm_clay.reset_solve_counts()
            local nx, ny = s.geometry.x + 360, s.geometry.y + 240
            -- Space-separated: the dispatcher joins the first two words into
            -- the "client.move" handler name (parts[1].."."..parts[2]).
            local resp = ipc.dispatch(
                "client move " .. c_float.id .. " " .. nx .. " " .. ny, -1)
            assert(type(resp) == "string" and not resp:find("ERROR", 1, true),
                "IPC client.move failed: " .. tostring(resp))
            return nil
        end
        if counts().merged < 1 and count < 12 then return nil end
        assert(counts().merged >= 1,
            "an IPC move must auto re-solve (merged solve) with no explicit arrange")
        utils.assert_geometry(c_float:geometry(), {
            x = s.geometry.x + 360,
            y = s.geometry.y + 240,
            width = 200, height = 150,
        }, 4)
        io.stderr:write("[TEST] PASS: IPC move auto-re-solves, box matches\n")
        return true
    end,

}

-- kill_clients defaults to true: the runner appends its own teardown that kills
-- the spawned clients and escalates to kill -9, so no bespoke cleanup step here.
runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
