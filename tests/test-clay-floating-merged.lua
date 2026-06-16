---------------------------------------------------------------------------
--- Test: the floating layout (clay.floating, a merge-capable descriptor) holds
--- its clients steady across repeated arranges.
---
--- clay.floating grafts root-attached at screen.geometry (bounds_source
--- "geometry"); its body positions each client at its own absolute geometry.
--- Routing it through the workarea node instead would add the node's padding +
--- useless_gap on every arrange, drifting every client down and to the right by
--- the gap each time (which focus-follows-mouse re-arrange makes continuous).
--- A non-zero gap is essential here -- the other merge tests use gap = 0, which
--- is exactly what hid this.
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
local function counts() return _somewm_clay.get_solve_counts() end

local CLASSES = { "fm_a", "fm_b" }
local tag, boxes

local steps = {
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.gap = 8           -- non-zero: the drift was gap-sized
        tag.layout = clay.floating
        return true
    end,
    function(count)
        if count == 1 then
            for _, cls in ipairs(CLASSES) do test_client(cls) end
        end
        local n = 0
        for _, cls in ipairs(CLASSES) do
            if utils.find_client_by_class(cls) then n = n + 1 end
        end
        return n == #CLASSES and true or nil
    end,

    -- Place each (normal, in-tiled-set) client at a distinct box, arrange once,
    -- and record where the merged solve put them.
    function(count)
        if count == 1 then
            local geo = screen.primary.geometry
            utils.find_client_by_class("fm_a"):geometry {
                x = geo.x + 120, y = geo.y + 90, width = 300, height = 200 }
            utils.find_client_by_class("fm_b"):geometry {
                x = geo.x + 520, y = geo.y + 320, width = 360, height = 240 }
            _somewm_clay.reset_solve_counts()
            awful.layout.arrange(screen.primary)
            return nil
        end
        if counts().merged < 1 and count < 10 then return nil end
        assert(counts().merged >= 1,
            "floating layout should reflect its clients via the descriptor merge")
        boxes = {}
        for _, cls in ipairs(CLASSES) do
            boxes[cls] = utils.find_client_by_class(cls):geometry()
        end
        return true
    end,

    -- Arrange several more times; the geometry must not move (the drift bug
    -- shifted every client by gap on each arrange).
    function(count)
        awful.layout.arrange(screen.primary)
        if count < 5 then return nil end
        for _, cls in ipairs(CLASSES) do
            local g = utils.find_client_by_class(cls):geometry()
            utils.assert_geometry(g, boxes[cls], 2)
        end
        io.stderr:write(
            "[TEST] PASS: floating clients stable across arranges (no drift)\n")
        return true
    end,

    function(count)
        if count == 1 then
            for _, c in ipairs(client.get()) do if c.valid then c:kill() end end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then return true end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
