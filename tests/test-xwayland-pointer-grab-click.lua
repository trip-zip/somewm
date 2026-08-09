---------------------------------------------------------------------------
--- Regression test: left click must not break an XWayland pointer grab.
---
--- A game grabs the pointer (test-x11-grab-client: confined grab, blank
--- cursor). Clicking inside the window runs the default mouse binding,
--- c:activate { context = "mouse_click" }, whose redundant client.focus = c
--- used to drive a deactivate/clear/re-enter cycle for X11 clients. Xwayland
--- turns that into FocusOut, tears the grab down, and destroys its pointer
--- constraint: capture lost on every click (issue reproduced by this test).
---
--- The click is injected with test-virtual-pointer-client so it traverses
--- the real buttonpress() path (root.fake_input bypasses it). Assertions:
--- the click reaches the grabbing client (BUTTON press) and produces no
--- FOCUS_OUT after the grab was established.
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")
local ruled  = require("ruled")

local GRAB_CLIENT = "./build-test/test-x11-grab-client"
local VPOINTER    = "./build-test/test-virtual-pointer-client"
local CLASS       = "grab_click"

if os.getenv("WLR_BACKENDS") == "headless" then
    io.stderr:write("SKIP: XWayland tests require visual mode (HEADLESS=0)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local function file_exists(path)
    local f = io.open(path, "r"); if not f then return false end
    f:close(); return true
end

for _, bin in ipairs({ GRAB_CLIENT, VPOINTER }) do
    if not file_exists(bin) then
        io.stderr:write("SKIP: " .. bin .. " not found (run meson compile first)\n")
        io.stderr:write("Test finished successfully.\n")
        awesome.quit()
        return
    end
end

local marker = string.format("/tmp/somewm-grab-click-%d.log",
                             os.time() * 1000 + math.random(0, 999))
os.remove(marker)

local function read_lines()
    local f = io.open(marker, "r"); if not f then return {} end
    local out = {}
    for line in f:lines() do out[#out + 1] = line end
    f:close()
    return out
end

local function grab_index(lines)
    for i, line in ipairs(lines) do
        if line == "GRAB 0" then return i end
    end
    return nil
end

-- Counts lines starting with the given prefix (FOCUS lines carry mode/detail).
local function count_after(lines, from, want)
    local n = 0
    for i = from, #lines do
        if lines[i]:find(want, 1, true) == 1 then n = n + 1 end
    end
    return n
end

runner.run_async(function()
    -- The somewmrc default left-click binding; tests/rc.lua has none.
    awful.mouse.append_client_mousebindings({
        awful.button({ }, 1, function(c)
            c:activate { context = "mouse_click" }
        end),
    })

    -- Workaround for a compositor defect: the first X client after the lazy
    -- XWayland start races its map against xwaylandready() and never maps
    -- compositor-side (fast minimal clients lose; xterm-sized ones win).
    -- Spawn and discard one client so the real one maps reliably; matched by
    -- name because the racy client never gets its class. Remove once the
    -- first-X11-client map race is fixed.
    do
        local warm = awful.spawn(string.format("%s /dev/null warmup_x11 0 0 50 50",
                                               GRAB_CLIENT))
        assert(type(warm) == "number", "warm-up spawn failed: " .. tostring(warm))
        local wc
        async.wait_for_condition(function()
            for _, cc in ipairs(client.get()) do
                if cc.name == "warmup_x11" then wc = cc; return true end
            end
        end, 10)
        assert(wc, "warm-up X client did not appear")
        os.execute("kill -9 " .. warm .. " 2>/dev/null")
        async.wait_for_condition(function() return not wc.valid end, 5)
        async.sleep(0.2)
    end

    -- The client grabs on pointer enter, so it must spawn floating in a box
    -- containing neither the compositor cursor's startup position (100, 100)
    -- nor Xwayland's X-side pointer resting position (the screen center);
    -- either one delivers EnterNotify at map and the grab fires early.
    local box = { x = 350, y = 40, width = 200, height = 150 }
    ruled.client.append_rule {
        rule = { class = CLASS },
        properties = { floating = true, x = box.x, y = box.y,
                       width = box.width, height = box.height },
    }

    local grab_pid = awful.spawn(string.format("%s %s %s %d %d %d %d",
        GRAB_CLIENT, marker, CLASS, box.x, box.y, box.width, box.height))
    assert(type(grab_pid) == "number", "spawn returned: " .. tostring(grab_pid))

    local c = async.wait_for_client(CLASS, 10)
    assert(c, "X11 grab client did not appear")
    assert(c.window and c.window > 0, "client is not an XWayland client")

    assert(async.wait_for_focus(CLASS, 5), "X11 grab client did not receive focus")
    assert(grab_index(read_lines()) == nil,
        "grab fired before the cursor entered the window; marker: ["
        .. table.concat(read_lines(), " | ") .. "]")

    local g = c:geometry()
    local cx = math.floor(g.x + g.width / 2)
    local cy = math.floor(g.y + g.height / 2)
    local sg = c.screen.geometry

    local function inject(mode)
        awful.spawn(string.format("%s %s %d %d %d %d", VPOINTER, mode, cx, cy,
                                  sg.width, sg.height))
    end

    -- Move the cursor into the window first; the client grabs on pointer
    -- enter, like a game entering mouse capture.
    inject("move")

    local gi
    async.wait_for_condition(function()
        gi = grab_index(read_lines())
        return gi ~= nil
    end, 5)
    assert(gi, "pointer grab did not succeed; marker: ["
        .. table.concat(read_lines(), " | ") .. "]")
    io.stderr:write("[TEST] pointer grab established\n")

    inject("click")
    local clicked = async.wait_for_condition(function()
        return count_after(read_lines(), gi, "BUTTON press") >= 1
    end, 5)
    assert(clicked, "click did not reach the grabbing client; marker: ["
        .. table.concat(read_lines(), " | ") .. "]")

    -- Give any focus fallout time to reach the client before asserting.
    async.sleep(0.5)

    local lines = read_lines()
    assert(count_after(lines, gi, "FOCUS_OUT") == 0,
        "left click broke the pointer grab (FocusOut delivered); marker: ["
        .. table.concat(lines, " | ") .. "]")
    assert(client.focus == c, "client lost compositor focus after click")

    -- The grab must still be operative: a second click still lands.
    inject("click")
    local clicked_again = async.wait_for_condition(function()
        return count_after(read_lines(), gi, "BUTTON press") >= 2
    end, 5)
    assert(clicked_again, "second click did not reach the grabbing client")
    async.sleep(0.3)
    assert(count_after(read_lines(), gi, "FOCUS_OUT") == 0,
        "second click broke the pointer grab (FocusOut delivered)")

    io.stderr:write("[ALL TESTS] PASS\n")

    if c.valid then c:kill() end
    os.execute("kill -9 " .. grab_pid .. " 2>/dev/null")
    async.wait_for_no_clients(5)
    os.remove(marker)
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
