-- Test: floating layout must not maximize windows
-- Covers two scenarios:
--   1. Switching from tiling to floating preserves tiled geometry
--   2. Opening a new window in floating layout does not fill workarea
--
-- Note: Scenario 2 checks initial geometry at manage time via
-- request::manage signal. Some test terminals (kitty in headless)
-- may choose smaller sizes even when given workarea-sized set_size,
-- so we capture geometry at the earliest possible moment.
--
-- Regression test for PR #321 (acd0fa4) / issue #371
-- Run with: HEADLESS=1 make test-one TEST=tests/test-floating-layout.lua

local awful = require("awful")
local runner = require("_runner")
local test_client = require("_client")

runner.run_steps({
    -- =================================================================
    -- SCENARIO 1: Switch tiling -> floating, windows must keep tiled size
    -- =================================================================
    function()
        -- Start in tiling layout, spawn 3 clients
        awful.layout.set(awful.layout.suit.tile)
        test_client(nil, "tile_a")
        test_client(nil, "tile_b")
        test_client(nil, "tile_c")
        return true
    end,
    function()
        -- Wait for all 3 clients
        if #client.get() < 3 then return end

        -- Record tiled geometries before switch
        local pre_geos = {}
        for _, c in ipairs(client.get()) do
            local g = c:geometry()
            pre_geos[c] = { width = g.width, height = g.height }
        end

        -- Switch to floating
        awful.layout.set(awful.layout.suit.floating)

        -- Verify: geometry did not grow after switch
        for _, c in ipairs(client.get()) do
            local g = c:geometry()
            local pre = pre_geos[c]
            assert(g.width <= pre.width + 2 and g.height <= pre.height + 2,
                "BUG: client '" .. (c.class or "?") ..
                "' grew from " .. pre.width .. "x" .. pre.height ..
                " to " .. g.width .. "x" .. g.height ..
                " after tiling->floating switch")
        end
        return true
    end,

    -- =================================================================
    -- SCENARIO 2: New window in floating layout must not be forced to
    -- workarea size. We record geometry at manage time (before the
    -- client can resize itself) and verify the compositor did not set
    -- it to the full workarea.
    -- =================================================================
    function()
        -- Still in floating layout. Capture manage-time geometry via
        -- a one-shot signal so we observe what the compositor chose,
        -- not what the terminal later resized to.
        _G._float_manage_geo = nil
        _G._float_manage_conn = function(c)
            _G._float_manage_geo = { width = c.width, height = c.height }
            client.disconnect_signal("request::manage", _G._float_manage_conn)
        end
        client.connect_signal("request::manage", _G._float_manage_conn)
        test_client(nil, "float_new")
        return true
    end,
    function()
        -- Wait for the manage signal to fire
        if not _G._float_manage_geo then return end

        local wa = awful.screen.focused().workarea
        local g = _G._float_manage_geo

        -- The compositor must not have forced the client to fill
        -- the workarea. Allow a small tolerance for borders.
        assert(g.width < wa.width - 10 or g.height < wa.height - 10,
            "BUG: new client in floating layout was forced to workarea size " ..
            g.width .. "x" .. g.height ..
            " (workarea " .. wa.width .. "x" .. wa.height .. ")")
        return true
    end,

    -- =================================================================
    -- SCENARIO 3: Tile -> float -> tile -> float cycle
    -- =================================================================
    function()
        awful.layout.set(awful.layout.suit.tile)
        return true
    end,
    function()
        -- Record tiled sizes
        _G._tiled_geos = {}
        for _, c in ipairs(client.get()) do
            local g = c:geometry()
            _G._tiled_geos[c] = { width = g.width, height = g.height }
        end

        -- Switch back to floating
        awful.layout.set(awful.layout.suit.floating)

        -- Verify: no client grew beyond its tiled size
        for _, c in ipairs(client.get()) do
            local g = c:geometry()
            local tg = _G._tiled_geos[c]
            assert(g.width <= tg.width + 2 and g.height <= tg.height + 2,
                "BUG: client '" .. (c.class or "?") ..
                "' grew from " .. tg.width .. "x" .. tg.height ..
                " to " .. g.width .. "x" .. g.height ..
                " after tile->float->tile->float cycle")
        end
        return true
    end,
})
