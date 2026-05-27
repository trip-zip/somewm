---------------------------------------------------------------------------
--- Test: a non-stretched wibar keeps its length and is aligned along the edge.
--
-- compose_screen folds wibars into the screen solve. A stretched bar (the
-- default) fills the edge; a non-stretched one keeps its own width/height and
-- is positioned left/center/right (top/center/bottom for vertical bars) by
-- `align`. This verifies the solved drawin geometry for each case, against the
-- real C Clay solve (not the reference solver).
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")

local s = screen.primary
local tag = s.tags[1]
local bar

-- Solved geometry is integer-floored and the screen origin may be nonzero;
-- allow a couple of pixels of slack.
local TOL = 3
local BAR_W = 400

local function approx(a, b) return math.abs(a - b) <= TOL end

local steps = {
    function()
        tag:view_only()
        tag.layout = awful.layout.suit.tile
        tag.gap = 0
        bar = awful.wibar {
            position = "top", screen = s, height = 20,
            width = BAR_W, align = "left",
        }
        io.stderr:write(string.format("[TEST] screen %dx%d+%d+%d, bar width=%d\n",
            s.geometry.width, s.geometry.height, s.geometry.x, s.geometry.y, BAR_W))
        return true
    end,

    -- align=left: full requested width, pinned to the left edge.
    function(count)
        local g = bar:geometry()
        if not approx(g.width, BAR_W) or not approx(g.x, s.geometry.x) then
            if count >= 20 then
                error(string.format("left: got %dx%d+%d+%d", g.width, g.height, g.x, g.y))
            end
            return nil
        end
        io.stderr:write(string.format("[TEST] PASS left: %dx%d+%d+%d\n",
            g.width, g.height, g.x, g.y))
        return true
    end,

    -- align=right: same width, pinned to the right edge.
    function(count)
        if count == 1 then bar.align = "right"; return nil end
        local g = bar:geometry()
        local want_x = s.geometry.x + s.geometry.width - BAR_W
        if not approx(g.width, BAR_W) or not approx(g.x, want_x) then
            if count >= 20 then
                error(string.format("right: got x=%d want_x=%d w=%d", g.x, want_x, g.width))
            end
            return nil
        end
        io.stderr:write(string.format("[TEST] PASS right: %dx%d+%d+%d\n",
            g.width, g.height, g.x, g.y))
        return true
    end,

    -- align=centered: same width, centered along the edge.
    function(count)
        if count == 1 then bar.align = "centered"; return nil end
        local g = bar:geometry()
        local want_x = s.geometry.x + math.floor((s.geometry.width - BAR_W) / 2)
        if not approx(g.width, BAR_W) or not approx(g.x, want_x) then
            if count >= 20 then
                error(string.format("centered: got x=%d want_x=%d w=%d", g.x, want_x, g.width))
            end
            return nil
        end
        io.stderr:write(string.format("[TEST] PASS centered: %dx%d+%d+%d\n",
            g.width, g.height, g.x, g.y))
        return true
    end,

    -- stretch=true: ignore width/align, fill the whole edge.
    function(count)
        if count == 1 then bar.stretch = true; return nil end
        local g = bar:geometry()
        if not approx(g.width, s.geometry.width) or not approx(g.x, s.geometry.x) then
            if count >= 20 then
                error(string.format("stretched: got x=%d w=%d want w=%d",
                    g.x, g.width, s.geometry.width))
            end
            return nil
        end
        io.stderr:write(string.format("[TEST] PASS stretched: %dx%d+%d+%d\n",
            g.width, g.height, g.x, g.y))
        return true
    end,

    function()
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
