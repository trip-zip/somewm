---------------------------------------------------------------------------
--- Test: descriptor layouts merge every client into the one screen solve
--- across a range of client counts (N = 1, 2, 3, 4).
---
--- tile and fair reshape their split/grid as N grows, so this exercises the
--- merged solve at each count: every client drives a "merged" screen solve and
--- lands inside the workarea. Run under SOMEWM_TREE_ASSERT=abort, the
--- tree==scene assertion then checks every client against the box Clay solved
--- (descriptors are strict: no allow-list).
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

local CLASSES = { "mx_a", "mx_b", "mx_c", "mx_d" }
local tag

local function counts() return _somewm_clay.get_solve_counts() end

-- Spawn the nth client (if missing) and wait until exactly n exist.
local function spawn_to(n)
    return function(count)
        if count == 1 and not utils.find_client_by_class(CLASSES[n]) then
            test_client(CLASSES[n])
        end
        local have = 0
        for i = 1, n do
            if utils.find_client_by_class(CLASSES[i]) then have = have + 1 end
        end
        return have == n and true or nil
    end
end

-- Select the layout, then reset+arrange and assert a merged solve placed all n
-- clients inside the workarea.
local function measure(label, layout, n)
    return {
        function() tag.layout = layout; return true end,
        function(count)
            if count == 1 then
                _somewm_clay.reset_solve_counts()
                awful.layout.arrange(screen.primary)
                return nil
            end
            if counts().merged < 1 and count < 10 then return nil end
            assert(counts().merged >= 1,
                label .. " N=" .. n .. ": should drive a merged screen solve")
            local wa = screen.primary.workarea
            local seen = 0
            for _, c in ipairs(tag:clients()) do
                local g, bw = c:geometry(), c.border_width or 0
                local tol = 2 * bw + 4
                assert(g.x >= wa.x - tol and g.y >= wa.y - tol
                    and g.x + g.width  <= wa.x + wa.width  + tol
                    and g.y + g.height <= wa.y + wa.height + tol,
                    string.format("%s N=%d: client %s escapes workarea",
                        label, n, tostring(c.class)))
                seen = seen + 1
            end
            assert(seen == n,
                label .. " N=" .. n .. ": expected " .. n .. " clients, saw " .. seen)
            io.stderr:write(string.format(
                "[TEST] PASS: %s N=%d merged, all %d clients in workarea\n",
                label, n, n))
            return true
        end,
    }
end

local steps = {
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.gap = 0
        tag.master_count = 1
        tag.master_width_factor = 0.5
        return true
    end,
}

local function add(list) for _, s in ipairs(list) do steps[#steps + 1] = s end end

for n = 1, #CLASSES do
    add({ spawn_to(n) })
    add(measure("clay.tile", clay.tile, n))
    add(measure("clay.fair", clay.fair, n))
end

steps[#steps + 1] = function(count)
    if count == 1 then
        for _, c in ipairs(client.get()) do if c.valid then c:kill() end end
    end
    if #client.get() == 0 then return true end
    if count >= 10 then return true end
end

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
