---------------------------------------------------------------------------
--- Test: a context-body layout receives the screen OBJECT as ctx.screen.
---
--- descriptor_to_root threads p.screen into the layout context, and p.screen
--- is a numeric index (awful.layout.parameters sets it from screen.index).
--- Without normalization a context body that reads ctx.screen as a screen
--- object (ctx.screen.geometry, ctx.screen.selected_tag, ...) indexes a
--- number and breaks. This locks the seam: ctx.screen is the screen object.
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
local layout = require("somewm.layout")

-- A throwaway merge-capable layout whose body records what ctx.screen is and
-- otherwise lays the clients out in a plain row.
local seen
local probe = clay.layout {
    name           = "clay.screenprobe",
    body_signature = "context",
    merged_capable = true,
    body           = function(ctx)
        seen = ctx.screen
        local nodes = {}
        for _, c in ipairs(ctx.children) do
            nodes[#nodes + 1] = layout.client(c)
        end
        return layout.row(nodes)
    end,
}

local tag

local steps = {
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = probe
        tag.gap = 0
        return true
    end,

    -- Spawn one tiled client so descriptor_to_root reaches the body (it
    -- returns early when there are no clients to place).
    function(count)
        if count == 1 then test_client("screenprobe_a") end
        return utils.find_client_by_class("screenprobe_a") and true or nil
    end,

    -- Arrange, then assert ctx.screen was a screen object, not a number.
    function(count)
        if count == 1 then
            seen = nil
            awful.layout.arrange(screen.primary)
            return nil
        end
        if seen == nil then
            if count >= 20 then
                assert(false, "layout body never ran; ctx.screen not captured")
            end
            return nil
        end

        assert(type(seen) ~= "number", string.format(
            "ctx.screen must be a screen object, got a number (%s)",
            tostring(seen)))
        -- Safe to index now that it is not a number; prove it is the right one.
        assert(seen.index == screen.primary.index, string.format(
            "ctx.screen.index=%s should equal screen.primary.index=%d",
            tostring(seen.index), screen.primary.index))
        io.stderr:write("[TEST] PASS: ctx.screen is the screen object\n")
        return true
    end,

    -- Cleanup
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
