---------------------------------------------------------------------------
--- Test: clay.max writes workarea geometry to every client.
--
-- Regression for the bug where the body returned a tree with only
-- clients[1] as a leaf, leaving clients[2..n] with stale geometry from
-- whatever layout last ran.
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

local tag

local function get_geo(c)
    return c:geometry()
end

local function expected_rect(c, wa)
    local bw2 = (c.border_width or 0) * 2
    return {
        x = wa.x,
        y = wa.y,
        width = math.max(1, wa.width - bw2),
        height = math.max(1, wa.height - bw2),
    }
end

local function assert_fills_workarea(c, wa, label)
    local g = get_geo(c)
    local e = expected_rect(c, wa)
    io.stderr:write(string.format(
        "[TEST] %s: x=%d y=%d w=%d h=%d (expected x=%d y=%d w=%d h=%d)\n",
        label, g.x, g.y, g.width, g.height, e.x, e.y, e.width, e.height))
    -- Tolerance covers integer rounding inside Clay (floor of float coords).
    local tol = 2
    assert(math.abs(g.x - e.x) <= tol,
        string.format("%s: x=%d not near %d", label, g.x, e.x))
    assert(math.abs(g.y - e.y) <= tol,
        string.format("%s: y=%d not near %d", label, g.y, e.y))
    assert(math.abs(g.width - e.width) <= tol,
        string.format("%s: width=%d not near %d", label, g.width, e.width))
    assert(math.abs(g.height - e.height) <= tol,
        string.format("%s: height=%d not near %d", label, g.height, e.height))
end

local function spawn_step(name)
    return function(count)
        if count == 1 then test_client(name) end
        return utils.find_client_by_class(name) and true or nil
    end
end

local function arrange_then(check)
    return function(count)
        if count == 1 then
            awful.layout.arrange(screen.primary)
            return nil
        end
        return check()
    end
end

local steps = {
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = clay.max
        tag.gap = 0
        io.stderr:write("[TEST] Set clay.max layout\n")
        return true
    end,

    spawn_step("clay_max_a"),
    arrange_then(function()
        local cls = tag:clients()
        if #cls < 1 then return nil end
        local wa = screen.primary.workarea
        assert_fills_workarea(cls[1], wa, "n=1 client[1]")
        io.stderr:write("[TEST] PASS: single client fills workarea\n")
        return true
    end),

    spawn_step("clay_max_b"),
    arrange_then(function()
        local cls = tag:clients()
        if #cls < 2 then return nil end
        local wa = screen.primary.workarea
        assert_fills_workarea(cls[1], wa, "n=2 client[1]")
        assert_fills_workarea(cls[2], wa, "n=2 client[2]")
        io.stderr:write("[TEST] PASS: two clients both fill workarea\n")
        return true
    end),

    spawn_step("clay_max_c"),
    spawn_step("clay_max_d"),
    arrange_then(function()
        local cls = tag:clients()
        if #cls < 4 then return nil end
        local wa = screen.primary.workarea
        for i, c in ipairs(cls) do
            assert_fills_workarea(c, wa,
                string.format("n=4 client[%d]", i))
        end
        io.stderr:write("[TEST] PASS: four clients all fill workarea\n")
        return true
    end),

    -- Switch to tile, then back to max: clients[2..n] get tile-sized
    -- geometry under tile, then must be re-stretched to workarea on
    -- return to max. This is the exact failure mode of the original bug:
    -- without writing geometry to clients[2..n] under max, they keep the
    -- tile-shaped rect from the previous arrange.
    function(count)
        if count == 1 then
            tag.layout = clay.tile
            awful.layout.arrange(screen.primary)
            return nil
        end
        return true
    end,
    function(count)
        if count == 1 then
            tag.layout = clay.max
            awful.layout.arrange(screen.primary)
            return nil
        end
        local cls = tag:clients()
        if #cls < 4 then return nil end
        local wa = screen.primary.workarea
        for i, c in ipairs(cls) do
            assert_fills_workarea(c, wa,
                string.format("after tile->max client[%d]", i))
        end
        io.stderr:write("[TEST] PASS: tile->max restores workarea geometry for all clients\n")
        return true
    end,

    function(count)
        if count == 1 then
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then
            local pids = test_client.get_spawned_pids()
            for _, pid in ipairs(pids) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })
