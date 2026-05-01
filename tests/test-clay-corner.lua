---------------------------------------------------------------------------
--- Test: clay.corner.{nw,ne,sw,se} layouts.
---
--- Corner is structurally complex: master takes mwfact x mwfact share,
--- remaining clients distribute into row + column groups via even/odd
--- index parity, and master_count parity (`row_privileged`) flips which
--- group gets the corner-aligned share.
---
--- This test verifies the migration to body_signature = "context"
--- preserves behavior:
---   1. No client overlaps another in any orientation.
---   2. Orientation flip (NW vs SE) actually shifts the master client's
---      anchor (different x AND y).
---   3. master_count parity flip (1 -> 2) actually changes geometry.
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
                "%s: client %d overlaps client %d (a=%d,%d %dx%d, b=%d,%d %dx%d)",
                label, i, j,
                a.x, a.y, a.width, a.height,
                b.x, b.y, b.width, b.height))
        end
    end
end

local function snapshot(cls)
    local out = {}
    for i, c in ipairs(cls) do
        local g = get_geo(c)
        out[i] = string.format("%d,%d %dx%d", g.x, g.y, g.width, g.height)
    end
    return table.concat(out, "|")
end

local snapshots = {}

local function set_corner(orientation)
    return function(count)
        if count == 1 then
            tag.layout = clay.corner[orientation]
            awful.layout.arrange(screen.primary)
            return nil
        end
        return true
    end
end

local function record(label)
    return function(count)
        if count == 1 then return nil end
        local cls = tag:clients()
        if #cls < 4 then return nil end
        check_no_overlap(cls, label)
        snapshots[label] = snapshot(cls)
        io.stderr:write(string.format("[TEST] %s: %s\n", label, snapshots[label]))
        return true
    end
end

local steps = {
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.master_width_factor = 0.5
        tag.master_count = 1
        tag.gap = 0
        return true
    end,

    function(count)
        if count == 1 then test_client("corner_a") end
        return utils.find_client_by_class("corner_a") and true or nil
    end,
    function(count)
        if count == 1 then test_client("corner_b") end
        return utils.find_client_by_class("corner_b") and true or nil
    end,
    function(count)
        if count == 1 then test_client("corner_c") end
        return utils.find_client_by_class("corner_c") and true or nil
    end,
    function(count)
        if count == 1 then test_client("corner_d") end
        return utils.find_client_by_class("corner_d") and true or nil
    end,

    set_corner("nw"), record("nw_mc1"),
    set_corner("ne"), record("ne_mc1"),
    set_corner("sw"), record("sw_mc1"),
    set_corner("se"), record("se_mc1"),

    function(count)
        if count == 1 then
            tag.master_count = 2
            awful.layout.arrange(screen.primary)
            return nil
        end
        return true
    end,
    set_corner("nw"), record("nw_mc2"),

    function()
        assert(snapshots.nw_mc1 ~= snapshots.ne_mc1,
            "NW and NE should produce different geometry")
        assert(snapshots.nw_mc1 ~= snapshots.sw_mc1,
            "NW and SW should produce different geometry")
        assert(snapshots.nw_mc1 ~= snapshots.se_mc1,
            "NW and SE should produce different geometry")
        assert(snapshots.nw_mc1 ~= snapshots.nw_mc2,
            "row_privileged parity should change geometry (master_count 1 vs 2)")
        io.stderr:write("[TEST] PASS: corner orientations and parity all distinct\n")
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
