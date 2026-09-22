---------------------------------------------------------------------------
-- Test: an output plugged in while locked shows the lock and nothing else.
--
-- The compositor declares the lock backdrop itself, sized to the output, so
-- a screen that appears mid-lock is covered before the config's screen
-- handler can register a cover for it. One tree per output carries it: the
-- dump prints one header per output and the backdrop is the topmost band.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")
local lock = require("_lock_helper")

if not awesome._test_add_output then
    io.stderr:write("SKIP: awesome._test_add_output not available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local initial = screen.count()
local lock_surface, fresh

-- The declared tree of one screen, up to the realized list.
local function tree(s)
    local out = {}
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if line == "  realized:" then break end
        out[#out + 1] = line
    end
    return out
end

runner.run_steps({
    -- A wibar on screen 1, so there is desktop content to keep out.
    function()
        local bar = awful.wibar({ position = "top", screen = screen[1], height = 24 })
        bar:setup({
            layout = wibox.layout.fixed.horizontal,
            { widget = wibox.widget.textbox, text = "desktop" },
        })
        lock_surface = lock.setup()
        return true
    end,

    function()
        awesome.lock()
        assert(awesome.locked, "should be locked")
        lock_surface.visible = true
        return true
    end,

    -- A new output while locked, with no cover registered for it.
    function()
        assert(awesome._test_add_output(800, 600), "_test_add_output failed")
        return true
    end,

    function(count)
        if screen.count() < initial + 1 then
            assert(count < 20, "the new screen never appeared")
            return nil
        end
        fresh = screen[screen.count()]
        return true
    end,

    -- The new screen's tree: one header, a LOCK backdrop at band 200, and
    -- nothing declared above it.
    function(count)
        local headers, backdrop, top = 0, nil, -math.huge

        for _, line in ipairs(tree(fresh)) do
            if line:match("^output %S+ scale") then
                headers = headers + 1
            else
                local band = tonumber(line:match(" band (%-?%d+)"))
                if band and band > top then top = band end
                if line:find("LOCK ", 1, true) and band == 200 then
                    backdrop = line
                end
            end
        end

        if not backdrop then
            assert(count < 30, "the new screen never declared the lock backdrop")
            return nil
        end
        assert(headers == 1,
            "the new screen's dump has " .. headers .. " headers, expected one")
        assert(top == 200,
            "something is declared above the lock backdrop, at band " .. top)
        io.stderr:write("[PASS] the hotplugged screen shows only the lock: "
            .. backdrop .. "\n")
        return true
    end,

    -- Nothing on the new screen answers the pointer either.
    function(count)
        local g = fresh.geometry
        local x, y = g.x + math.floor(g.width / 2), g.y + math.floor(g.height / 2)

        -- The pointer walk runs off the last frame, so move, let a frame
        -- land, and move again before reading.
        mouse.coords({ x = x, y = y })
        if count < 3 then return nil end
        mouse.coords({ x = x, y = y })
        assert(mouse.object_under_pointer() == nil,
            "something on the locked screen took the pointer")
        io.stderr:write("[PASS] the locked screen answers the pointer with nothing\n")
        lock.teardown()
        return true
    end,
})
