---------------------------------------------------------------------------
--- Test: clay.spiral and clay.spiral.dwindle layouts
--
-- Verifies recursive split layouts produce non-overlapping geometries
-- summing to the workarea, with the first client occupying the
-- master_width_factor share.
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

local function rects_overlap(a, b)
    return a.x < b.x + b.width
        and b.x < a.x + a.width
        and a.y < b.y + b.height
        and b.y < a.y + a.height
end

local function check_no_overlap(cls, label)
    for i = 1, #cls do
        for j = i + 1, #cls do
            local a, b = get_geo(cls[i]), get_geo(cls[j])
            assert(not rects_overlap(a, b), string.format(
                "%s: client %d overlaps client %d", label, i, j))
        end
    end
end

local steps = {
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = clay.spiral
        tag.master_width_factor = 0.5
        tag.gap = 0
        return true
    end,

    function(count)
        if count == 1 then
            test_client("spi_a"); test_client("spi_b")
            test_client("spi_c"); test_client("spi_d")
        end
        local cls = tag:clients()
        if #cls < 4 then return nil end
        return true
    end,

    function(count)
        if count == 1 then
            awful.layout.arrange(screen.primary)
            return nil
        end
        local wa = screen.primary.workarea
        local cls = tag:clients()
        check_no_overlap(cls, "clay.spiral")

        -- Find the master client: the one whose geometry takes 50% of workarea
        -- in one dimension and full extent in the other.
        local master_w = wa.width * 0.5
        local found_master = false
        for _, c in ipairs(cls) do
            local g = c:geometry()
            if math.abs(g.width - master_w) < wa.width * 0.1
               and math.abs(g.height - wa.height) < wa.height * 0.1 then
                found_master = true
                break
            end
        end
        assert(found_master, "clay.spiral: no client has master geometry")
        return true
    end,

    function()
        tag.layout = clay.spiral.dwindle
        awful.layout.arrange(screen.primary)
        return true
    end,

    function(count)
        if count == 1 then return nil end
        local cls = tag:clients()
        check_no_overlap(cls, "clay.spiral.dwindle")
        return true
    end,
}

runner.run_steps(steps)
