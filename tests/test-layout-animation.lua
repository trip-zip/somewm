---------------------------------------------------------------------------
--- Test: geometry-level animated layout transitions
--
-- Verifies that the layout_animation module:
-- 1. Snaps instantly when disabled
-- 2. Animates mwfact changes smoothly (clients reach target geometry)
-- 3. Handles rapid retargeting (multiple changes converge)
-- 4. Skips animation during mousegrabber (mouse drag)
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")
local layout_animation = require("somewm.layout_animation")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local tag

--- Check if the master client's outer width matches an expected mwfact.
-- @tparam number mwfact Expected master_width_factor
-- @tparam number tolerance Pixel tolerance
-- @treturn boolean,number Whether it matches, and actual outer width
local function master_width_matches(mwfact, tolerance)
    tolerance = tolerance or 30
    local wa = screen.primary.workarea
    local expected_w = math.floor(wa.width * mwfact)
    local master = awful.client.getmaster()
    if not master then return false, 0 end
    local actual_w = master:geometry().width + master.border_width * 2
    return math.abs(actual_w - expected_w) < tolerance, actual_w
end

local steps = {
    -- Set up tile layout, animation disabled. This primes settled_geo.
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = awful.layout.suit.tile
        layout_animation.enabled = false
        layout_animation.duration = 0.15
        tag.master_width_factor = 0.5
        return true
    end,

    -- Spawn two clients
    function(count)
        if count == 1 then test_client("tile_a") end
        if utils.find_client_by_class("tile_a") then return true end
    end,

    function(count)
        if count == 1 then test_client("tile_b") end
        if utils.find_client_by_class("tile_b") then return true end
    end,

    -- Let layout settle
    function(count)
        if count >= 3 then return true end
    end,

    ---------------------------------------------------------------------------
    -- Test 1: Disabled animation snaps instantly
    ---------------------------------------------------------------------------
    function(count)
        if count == 1 then
            layout_animation.enabled = false
            tag.master_width_factor = 0.65
            return nil
        end

        -- With animation disabled, master should already be at 0.65
        local ok, actual_w = master_width_matches(0.65)
        if ok then
            io.stderr:write(string.format(
                "[TEST] Instant snap: master.w=%d\n", actual_w))
            io.stderr:write("[TEST] PASS: disabled animation snaps instantly\n")
            return true
        end

        if count > 5 then
            io.stderr:write(string.format(
                "[TEST] FAIL: instant snap: master.w=%d\n", actual_w))
            assert(false, "mwfact did not snap when animation disabled")
        end
        return nil
    end,

    ---------------------------------------------------------------------------
    -- Test 2: Enabled animation reaches target
    ---------------------------------------------------------------------------
    function(count)
        if count == 1 then
            -- Reset to 0.5 with animation disabled (primes settled_geo)
            layout_animation.enabled = false
            tag.master_width_factor = 0.5
            return nil
        end
        if count < 4 then return nil end

        -- Enable animation and trigger change
        layout_animation.enabled = true
        tag.master_width_factor = 0.65
        return true
    end,

    function(count)
        -- Wait for animation to complete (duration is 0.15s)
        local ok, actual_w = master_width_matches(0.65)
        if ok then
            io.stderr:write(string.format(
                "[TEST] Animation done: master.w=%d\n", actual_w))
            io.stderr:write("[TEST] PASS: animation reaches target\n")
            return true
        end

        if count > 5 then
            io.stderr:write(string.format(
                "[TEST] FAIL: animation target: master.w=%d\n", actual_w))
            assert(false, "mwfact animation did not reach target")
        end
        return nil
    end,

    ---------------------------------------------------------------------------
    -- Test 3: Rapid retarget converges to final value
    ---------------------------------------------------------------------------
    function(count)
        if count == 1 then
            -- Reset
            layout_animation.enabled = false
            tag.master_width_factor = 0.5
            return nil
        end
        if count < 4 then return nil end

        -- Enable and fire two changes in quick succession
        layout_animation.enabled = true
        tag.master_width_factor = 0.55
        return true
    end,

    function(count)
        if count == 1 then
            -- Second change before first animation finishes
            tag.master_width_factor = 0.60
            return nil
        end

        local ok, actual_w = master_width_matches(0.60)
        if ok then
            io.stderr:write(string.format(
                "[TEST] Retarget done: master.w=%d\n", actual_w))
            io.stderr:write("[TEST] PASS: retarget converges to final value\n")
            return true
        end

        if count > 5 then
            io.stderr:write(string.format(
                "[TEST] FAIL: retarget converge: master.w=%d\n", actual_w))
            assert(false, "mwfact retarget did not converge to final value")
        end
        return nil
    end,

    ---------------------------------------------------------------------------
    -- Test 4: No animation during mousegrabber
    ---------------------------------------------------------------------------
    function(count)
        if count == 1 then
            layout_animation.enabled = false
            tag.master_width_factor = 0.5
            return nil
        end
        if count < 4 then return nil end

        layout_animation.enabled = true

        -- Start a fake mousegrabber to simulate mouse drag
        mousegrabber.run(function() return true end, "crosshair")
        tag.master_width_factor = 0.70
        return true
    end,

    function(count)
        -- With mousegrabber active, change should snap (no animation)
        if count == 1 then return nil end

        local ok, actual_w = master_width_matches(0.70)
        if ok then
            io.stderr:write("[TEST] PASS: no animation during mousegrabber\n")
            mousegrabber.stop()
            return true
        end

        if count > 5 then
            io.stderr:write(string.format(
                "[TEST] FAIL: mousegrabber snap: master.w=%d\n", actual_w))
            mousegrabber.stop()
            assert(false, "mwfact did not snap during mousegrabber")
        end
        return nil
    end,

    ---------------------------------------------------------------------------
    -- Cleanup
    ---------------------------------------------------------------------------
    function(count)
        if count == 1 then
            layout_animation.enabled = false
            tag.master_width_factor = 0.5
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
