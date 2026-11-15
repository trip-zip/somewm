---------------------------------------------------------------------------
--- Layer pointer constraints did not restrict motion or activate on a
--- keyboard grant. Confinement must use the surface's output position.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")
local utils = require("_utils")

local CLIENT = utils.binary_or_skip("./build-test/test-layer-client")
local POINTER = utils.binary_or_skip("./build-test/test-virtual-pointer-client")
if not CLIENT or not POINTER then return runner.skip("test helpers not built") end

local function has_event(path, event)
    local f = io.open(path)
    if not f then return false end
    local text = f:read("*a")
    f:close()
    return ("\n" .. text):find("\n" .. event .. "\n", 1, true) ~= nil
end

local function move(x, y)
    local s = screen[1].geometry
    local done, status, err
    -- Absolute protocol coordinates are relative to the layout origin.
    awful.spawn.easy_async({ POINTER, "move", tostring(x - s.x), tostring(y - s.y),
        tostring(s.width), tostring(s.height) }, function(_, stderr, _, code)
        done, status, err = true, code, stderr
    end)
    assert(async.wait_for_condition(function() return done end, 5, 0.01),
        "virtual pointer move timed out")
    assert(status == 0, "virtual pointer failed: " .. tostring(err))
end

local function set_output_position(pos)
    output[1].position = pos
    assert(async.wait_for_condition(function()
        local g = screen[1].geometry
        return g.x == pos.x and g.y == pos.y
    end, 2, 0.01), "output did not move to " .. pos.x .. "," .. pos.y)
end

runner.run_async(function()
    local function run_case(name, keyboard, constraint, verify)
        local marker, entered = os.tmpname(), os.tmpname()
        local s = screen[1].geometry
        move(s.x + 100, s.y + 100)
        local pid = awful.spawn({ CLIENT, "--namespace", name, "--keyboard", keyboard,
            "--constrain", constraint, "--constraint-marker", marker,
            "--pointer-marker", entered, "--anchor", "bottom,right", "--size", "200,100" })
        local surface
        assert(async.wait_for_condition(function()
            for _, ls in ipairs(layer_surface.get()) do
                if ls.namespace == name then surface = ls end
            end
            return surface and surface.mapped
                and (keyboard == "none" or surface.has_keyboard_focus)
        end, 5, 0.01), name .. ": layer surface did not map with requested focus")
        local g = surface.geometry
        -- Layer geometry is output-local. mouse.coords() is layout-global.
        local x, y = s.x + g.x + g.width / 2, s.y + g.y + g.height / 2
        move(x, y)
        assert(async.wait_for_condition(function() return has_event(entered, "entered") end,
            5, 0.01), name .. ": client did not receive pointer enter")
        local p = mouse.coords()
        assert(math.abs(p.x - x) <= 1 and math.abs(p.y - y) <= 1,
            name .. ": virtual pointer did not reach the surface center")
        verify(surface, pid, marker)
        awesome.kill(pid, 15)
        assert(async.wait_for_condition(function() return not surface.valid end, 5, 0.01),
            name .. ": layer client did not exit")
        os.remove(marker)
        os.remove(entered)
    end

    run_case("lock_motion", "exclusive", "lock", function(_, _, marker)
        assert(async.wait_for_condition(function() return has_event(marker, "locked") end,
            3, 0.01), "lock_motion: initial lock did not activate")
        local before = mouse.coords()
        local s = screen[1].geometry
        move(s.x + 50, s.y + 50)
        local after = mouse.coords()
        assert(after.x == before.x and after.y == before.y,
            "lock_motion: pointer must stay at its locked position")
    end)

    run_case("lock_grant", "none", "lock", function(surface, pid, marker)
        assert(not has_event(marker, "locked"), "lock_grant: no lock before keyboard grant")
        awesome.kill(pid, 12)
        assert(async.wait_for_condition(function() return surface.has_keyboard_focus end,
            5, 0.01), "lock_grant: keyboard focus was not granted")
        assert(async.wait_for_condition(function() return has_event(marker, "locked") end,
            3, 0.01), "lock_grant: lock must activate on keyboard grant")
    end)

    local original = output[1].position
    set_output_position({ x = 320, y = 180 })
    run_case("confine_motion", "exclusive", "confine", function(surface, _, marker)
        assert(async.wait_for_condition(function() return has_event(marker, "confined") end,
            3, 0.01), "confine_motion: initial confinement did not activate")
        local s = screen[1].geometry
        move(s.x + 50, s.y + 50)
        local p, g = mouse.coords(), surface.geometry
        local x, y = p.x - s.x - g.x, p.y - s.y - g.y
        assert(x >= 0 and x < g.width and y >= 0 and y < g.height,
            "confine_motion: pointer must stay inside surface geometry")
    end)
    set_output_position(original)
    runner.done()
end)
