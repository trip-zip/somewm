---------------------------------------------------------------------------
--- Test: carousel edge peeking
--
-- Verifies that:
-- 1. carousel.peek_width insets client geometry from viewport edges
-- 2. Columns are sized relative to effective viewport (viewport - 2*peek)
-- 3. peek_width=0 gives full-width columns
-- 4. Adjacent columns show their edges in peek zones
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")
local carousel = awful.layout.suit.carousel

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

carousel.scroll_duration = 0

local tag
local c1, c2, c3

local steps = {
    -- Setup
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = carousel
        tag.gap = 0
        carousel.peek_width = 0
        carousel.set_center_mode("on-overflow")
        return true
    end,

    ---------------------------------------------------------------------------
    -- Test 1: Single client with peek insets geometry
    ---------------------------------------------------------------------------

    function(count)
        if count == 1 then test_client("peek_a") end
        c1 = utils.find_client_by_class("peek_a")
        if c1 then return true end
    end,

    -- Set peek_width = 50, verify inset
    function(count)
        if count == 1 then
            carousel.peek_width = 50
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g = c1:geometry()
        local bw = c1.border_width or 0
        local peek = 50

        io.stderr:write(string.format(
            "[TEST] Peek=50: client x=%d w=%d, wa x=%d w=%d, bw=%d\n",
            g.x, g.width, wa.x, wa.width, bw))

        -- Client left edge should be inset by peek + gap (gap=0 here)
        assert(g.x >= wa.x + peek - 2,
            string.format("Client x=%d should be >= wa.x+peek=%d",
                g.x, wa.x + peek))

        -- Client width should be effective_viewport - 2*bw - 2*gap
        local effective_viewport = wa.width - 2 * peek
        local expected_width = effective_viewport - 2 * bw
        assert(math.abs(g.width - expected_width) < 5,
            string.format("Client width %d should be ~%d (effective_viewport - borders)",
                g.width, expected_width))

        -- Client right edge should leave room for right peek zone
        local right_edge = g.x + g.width + 2 * bw
        assert(right_edge <= wa.x + wa.width - peek + 2,
            string.format("Client right edge %d should be <= wa.right-peek=%d",
                right_edge, wa.x + wa.width - peek))

        io.stderr:write("[TEST] PASS: peek_width insets client geometry\n")
        return true
    end,

    -- Set peek_width = 0, verify full-width
    function(count)
        if count == 1 then
            carousel.peek_width = 0
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g = c1:geometry()
        local bw = c1.border_width or 0

        io.stderr:write(string.format(
            "[TEST] Peek=0: client x=%d w=%d, wa x=%d w=%d\n",
            g.x, g.width, wa.x, wa.width))

        -- With peek=0, client should use the full workarea width
        local expected_width = wa.width - 2 * bw
        assert(math.abs(g.width - expected_width) < 5,
            string.format("Client width %d should be ~%d with peek=0",
                g.width, expected_width))

        io.stderr:write("[TEST] PASS: peek_width=0 gives full-width columns\n")
        return true
    end,

    -- Kill first client for next test
    function()
        if c1 and c1.valid then c1:kill() end
        return true
    end,

    ---------------------------------------------------------------------------
    -- Test 2: Adjacent columns visible in peek zones
    ---------------------------------------------------------------------------

    function(count)
        if count == 1 then test_client("peek_b") end
        c1 = utils.find_client_by_class("peek_b")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("peek_c") end
        c2 = utils.find_client_by_class("peek_c")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("peek_d") end
        c3 = utils.find_client_by_class("peek_d")
        if c3 then return true end
    end,

    -- Set peek=50, focus middle column (c2), check adjacent column edges
    function(count)
        if count == 1 then
            carousel.peek_width = 50
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        local g2 = c2:geometry()
        local g3 = c3:geometry()
        local bw = c1.border_width or 0
        local peek = 50

        io.stderr:write(string.format(
            "[TEST] Peek zones: c1=[%d,%d] c2=[%d,%d] c3=[%d,%d] wa=[%d,%d]\n",
            g1.x, g1.x + g1.width, g2.x, g2.x + g2.width,
            g3.x, g3.x + g3.width, wa.x, wa.x + wa.width))

        -- c2 (focused) should be inset from edges
        assert(g2.x >= wa.x + peek - 2,
            string.format("Focused column x=%d should be >= wa.x+peek=%d",
                g2.x, wa.x + peek))

        -- c1 (left adjacent): right edge should be visible in left peek zone
        local c1_right = g1.x + g1.width + 2 * bw
        -- With gap=0 and full-width columns: c1's right edge = wa.x + peek
        -- It should extend into the visible area (right edge > wa.x)
        io.stderr:write(string.format(
            "[TEST] c1 right edge=%d, wa.x=%d, left peek zone=[%d,%d]\n",
            c1_right, wa.x, wa.x, wa.x + peek))

        assert(c1_right > wa.x,
            string.format("c1 right edge %d should extend past wa.x=%d (peek zone)",
                c1_right, wa.x))
        assert(c1_right <= wa.x + peek + 2,
            string.format("c1 right edge %d should be within left peek zone (wa.x+peek=%d)",
                c1_right, wa.x + peek))

        -- c3 (right adjacent): left edge should be visible in right peek zone
        local right_peek_start = wa.x + wa.width - peek
        io.stderr:write(string.format(
            "[TEST] c3 x=%d, right peek zone=[%d,%d]\n",
            g3.x, right_peek_start, wa.x + wa.width))

        assert(g3.x < wa.x + wa.width,
            string.format("c3 x=%d should be within screen (<%d)",
                g3.x, wa.x + wa.width))
        assert(g3.x >= right_peek_start - 2,
            string.format("c3 x=%d should be in right peek zone (>=%d)",
                g3.x, right_peek_start))

        io.stderr:write("[TEST] PASS: adjacent columns visible in peek zones\n")
        return true
    end,

    -- Cleanup
    test_client.step_force_cleanup(function()
        carousel.peek_width = 0
    end),
}

runner.run_steps(steps, { kill_clients = false })
