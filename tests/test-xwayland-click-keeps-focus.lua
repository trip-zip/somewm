local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")
local ruled  = require("ruled")

local GRAB_CLIENT = "./build-test/test-x11-grab-client"
local VPOINTER    = "./build-test/test-virtual-pointer-client"
local CLASS       = "Test click focus"

local function skip(reason)
    io.stderr:write("SKIP: " .. reason .. "\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
end

if os.getenv("WLR_BACKENDS") == "headless" then
    return skip("XWayland tests require visual mode (HEADLESS=0)")
end

local function file_exists(path)
    local f = io.open(path, "r"); if not f then return false end
    f:close(); return true
end

for _, bin in ipairs({ GRAB_CLIENT, VPOINTER }) do
    if not file_exists(bin) then
        return skip(bin .. " not found (run meson compile first)")
    end
end

local marker = string.format("/tmp/somewm-click-focus-%d.log",
                             os.time() * 1000 + math.random(0, 999))
os.remove(marker)

local function read_lines()
    local f = io.open(marker, "r"); if not f then return {} end
    local out = {}
    for line in f:lines() do out[#out + 1] = line end
    f:close()
    return out
end

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

    -- Warm up lazy Xwayland before mapping the test client.
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

    local box = { x = 350, y = 40, width = 200, height = 150 }
    ruled.client.append_rule {
        rule = { class = CLASS },
        properties = { floating = true, x = box.x, y = box.y,
                       width = box.width, height = box.height },
    }

    local grab_pid = awful.spawn(string.format("%s %s %q %d %d %d %d no-grab",
        GRAB_CLIENT, marker, CLASS, box.x, box.y, box.width, box.height))
    assert(type(grab_pid) == "number", "spawn returned: " .. tostring(grab_pid))

    local c = async.wait_for_client(CLASS, 10)
    assert(c, "X11 grab client did not appear")
    assert(c.window and c.window > 0, "client is not an XWayland client")

    assert(async.wait_for_focus(CLASS, 5), "X11 grab client did not receive focus")
    assert(async.wait_for_condition(function()
        return count_after(read_lines(), 1, "FOCUS_IN") > 0
    end, 5), "X11 client did not receive initial FOCUS_IN")

    local g = c:geometry()
    local cx = math.floor(g.x + g.width / 2)
    local cy = math.floor(g.y + g.height / 2)
    local sg = c.screen.geometry

    local function inject(mode)
        awful.spawn(string.format("%s %s %d %d %d %d", VPOINTER, mode, cx, cy,
                                  sg.width, sg.height))
    end

    inject("move")
    assert(async.wait_for_condition(function()
        return count_after(read_lines(), 1, "ENTER") > 0
    end, 5), "pointer did not enter the X11 client")
    assert(client.focus == c, "client is not focused before the click")

    local click_start = #read_lines() + 1
    inject("click")
    local clicked = async.wait_for_condition(function()
        return count_after(read_lines(), click_start, "BUTTON press") > 0
    end, 5)
    assert(async.wait_for_condition(function()
        return count_after(read_lines(), click_start, "BUTTON release") > 0
    end, 5), "click release did not reach the X11 client")
    local click_lines = read_lines()
    local kept_focus = count_after(click_lines, click_start, "FOCUS_OUT") == 0
    local compositor_focus = client.focus == c
    io.stderr:write("[TEST] Step A: " .. (clicked and kept_focus and compositor_focus
        and "PASS" or "FAIL") .. "; marker: ["
        .. table.concat(click_lines, " | ", click_start) .. "]\n")

    local refocus_start = #read_lines() + 1
    client.focus = nil
    client.focus = c
    local redelivered = async.wait_for_condition(function()
        return count_after(read_lines(), refocus_start, "FOCUS_IN") > 0
    end, 5)
    local refocus_lines = read_lines()
    io.stderr:write("[TEST] Step B: " .. (redelivered and "PASS" or "FAIL")
        .. "; marker: [" .. table.concat(refocus_lines, " | ", refocus_start) .. "]\n")

    if c.valid then c:kill() end
    os.execute("kill -9 " .. grab_pid .. " 2>/dev/null")
    async.wait_for_no_clients(5)
    os.remove(marker)

    assert(redelivered, "nil then client focus did not deliver a new FOCUS_IN")
    assert(clicked, "click did not reach the X11 client")
    assert(kept_focus, "left click delivered FOCUS_OUT to the already-focused X11 client")
    assert(compositor_focus, "client lost compositor focus after click")
    io.stderr:write("[ALL TESTS] PASS\n")
    runner.done()
end)
