---------------------------------------------------------------------------
--- Regression test: titlebar event propagation (issue 593).
---
--- The compositor must NOT deliver pointer events to a client while the cursor
--- is over the client's server-side titlebar. The bug delivered wl_pointer
--- motion to the content surface with a coordinate that omitted the titlebar
--- height, so a titlebar hover landed on the client's top content rows.
---
--- test-pointer-logger maps an xdg_toplevel and appends every wl_pointer event
--- it receives (with decoded surface-local coords) to a marker file:
---     enter <sx> <sy> / motion <sx> <sy> / leave
--- We drive the cursor with mouse.coords + mouse._fake_motion and assert:
---   1. over content: an enter/motion arrives with correct content-local coords
---   2. over the titlebar (incl. the 1px-above-content band): NO enter/motion
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")

local CLIENT  = "./build-test/test-pointer-logger"
local APP_ID  = "tbptr_leak"
local TB_SIZE = 24

-- This test needs a real pointer device: it spawns a client and asserts on the
-- wl_pointer events the client receives. The headless backend (CI) has no input
-- device and never delivers pointer events, so skip there (run it headful).
if os.getenv("WLR_BACKENDS") == "headless" then
    io.stderr:write("SKIP: needs a real pointer device (headless backend has none)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local function file_exists(path)
    local f = io.open(path, "r"); if not f then return false end
    f:close(); return true
end

if not file_exists(CLIENT) then
    io.stderr:write("SKIP: " .. CLIENT .. " not found (run meson compile first)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local marker = string.format("/tmp/somewm-tbptr-%d.log", os.time() * 1000 + math.random(0, 999))
os.remove(marker)

local function clear_marker()
    local f = io.open(marker, "w"); if f then f:close() end
end

-- Parse the marker into a list of {kind=, x=, y=} events.
local function read_events()
    local f = io.open(marker, "r"); if not f then return {} end
    local out = {}
    for line in f:lines() do
        local kind, x, y = line:match("^(%a+)%s*(%-?%d*)%s*(%-?%d*)$")
        if kind then
            out[#out + 1] = { kind = kind, x = tonumber(x), y = tonumber(y) }
        end
    end
    f:close()
    return out
end

-- Drive a real motion event through motionnotify at (x, y): warp there (warp
-- alone does not run motionnotify), then nudge +/-1px via root.fake_input
-- relative motion (1.4 has no mouse._fake_motion); that routes through the full
-- motionnotify path.
local function probe_at(x, y)
    mouse.coords({ x = x, y = y })
    root.fake_input("motion_notify", true, 1, 0)
    root.fake_input("motion_notify", true, -1, 0)
end

local spawn_pid

runner.run_async(function()
    spawn_pid = awful.spawn(string.format("%s --app-id %s --marker %s", CLIENT, APP_ID, marker))
    assert(type(spawn_pid) == "number", "spawn returned: " .. tostring(spawn_pid))

    local c = async.wait_for_client(APP_ID, 5)
    assert(c, "pointer-logger client did not appear")

    -- Float at a known box and give it a top titlebar of known size.
    c.floating = true
    async.sleep(0.05)
    c:geometry({ x = 200, y = 200, width = 600, height = 400 })
    awful.titlebar(c, { size = TB_SIZE, position = "top" })
    async.sleep(0.2)

    local g  = c:geometry()
    local bw = c.border_width or 0
    -- Content origin (top-left titlebars only in this test): geometry + bw + titlebar.
    local ox = g.x + bw
    local oy = g.y + bw + TB_SIZE
    io.stderr:write(string.format("[TEST] geometry %dx%d+%d+%d bw=%d tb=%d -> content origin (%d,%d)\n",
        g.width, g.height, g.x, g.y, bw, TB_SIZE, ox, oy))

    -----------------------------------------------------------------------
    -- 1. Over content: enter/motion delivered at correct content-local coords.
    -----------------------------------------------------------------------
    clear_marker()
    local cx, cy = ox + 100, oy + 100   -- well inside content
    probe_at(cx, cy)
    async.sleep(0.2)

    local ev = read_events()
    local hit = nil
    for _, e in ipairs(ev) do
        if (e.kind == "enter" or e.kind == "motion") and e.x and e.y
                and math.abs(e.x - (cx - ox)) <= 2 and math.abs(e.y - (cy - oy)) <= 2 then
            hit = e
            break
        end
    end
    assert(hit, string.format(
        "[1] content hover: expected enter/motion near (%d,%d), got: %s",
        cx - ox, cy - oy, (function()
            local s = {} for _, e in ipairs(ev) do s[#s + 1] = e.kind .. " " .. tostring(e.x) .. " " .. tostring(e.y) end
            return "[" .. table.concat(s, " | ") .. "]"
        end)()))
    io.stderr:write(string.format("[TEST 1] PASS - content enter/motion at (%d,%d)\n", hit.x, hit.y))

    -----------------------------------------------------------------------
    -- 2. Over the titlebar (middle AND 1px-above-content band): NO leak.
    --    The cursor is above the content, so the client must receive no
    --    enter/motion - only possibly a leave.
    -----------------------------------------------------------------------
    local function assert_no_leak(label, ty)
        clear_marker()
        probe_at(ox + 100, ty)
        async.sleep(0.2)
        for _, e in ipairs(read_events()) do
            assert(e.kind ~= "enter" and e.kind ~= "motion", string.format(
                "[2:%s] LEAK: cursor over titlebar (y=%d) delivered %s %s %s to the client",
                label, ty, e.kind, tostring(e.x), tostring(e.y)))
        end
        io.stderr:write(string.format("[TEST 2:%s] PASS - no pointer events over titlebar y=%d\n", label, ty))
    end

    -- Re-enter content first so a leave is the only legitimate event on crossing.
    probe_at(ox + 100, oy + 100); async.sleep(0.1)
    assert_no_leak("middle", g.y + bw + math.floor(TB_SIZE / 2))
    probe_at(ox + 100, oy + 100); async.sleep(0.1)
    assert_no_leak("bottom-band", g.y + bw + TB_SIZE - 1)  -- 1px above content (old leak zone)

    -----------------------------------------------------------------------
    io.stderr:write("[ALL TESTS] PASS\n")

    -- Cleanup
    if c.valid then c:kill() end
    if spawn_pid then os.execute("kill -9 " .. spawn_pid .. " 2>/dev/null") end
    async.wait_for_no_clients(5)
    os.remove(marker)
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=90
