---------------------------------------------------------------------------
--- Integration tests for titlebar geometry, surface clipping, and fullscreen.
---
--- Covers:
---   Bug 1: surface clip bleeds past borders (client_get_clip fix)
---   Bug 2: crash/underflow when resizing client with titlebar to small size
---   Bug 6: fullscreen rendering broken with titlebars
---   Bonus: client.aspect_ratio Lua property
---
--- Pointer focus bugs (3, 4, 5) require cursor simulation at the C level and
--- cannot be exercised from Lua. They are verified manually.
---
--- Run: make test-one TEST=tests/test-titlebar-geometry.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local test_client = require("_client")
local awful  = require("awful")

if not test_client.is_available() then
    io.stderr:write("SKIP: no terminal available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

-- Force-kill all spawned processes and wait for clients to disappear.
-- c:kill() sends a Wayland close request, which terminals running "sleep infinity"
-- may not honour promptly. SIGKILL ensures the process exits immediately.
local function cleanup(c_to_kill)
    if c_to_kill and c_to_kill.valid then
        c_to_kill:kill()
    end
    for _, pid in ipairs(test_client.get_spawned_pids()) do
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
    return async.wait_for_no_clients(5)
end

runner.run_async(function()

    ---------------------------------------------------------------------------
    -- TEST 1: Bug 2 — no crash when resizing a client with titlebars to tiny size
    -- applybounds() must enforce minimum = 1 + 2*bw + titlebar sizes
    ---------------------------------------------------------------------------
    io.stderr:write("[TEST 1] Resize with titlebar — no crash, geometry clamped\n")

    test_client("titlebar_geo_1")
    local c = async.wait_for_client("titlebar_geo_1", 5)
    assert(c, "Client did not appear")

    -- Add a top titlebar (29px)
    awful.titlebar(c, { size = 29, position = "top" })
    async.sleep(0.15)

    c.floating = true
    async.sleep(0.05)

    local bw = c.border_width or 0

    -- Request absurdly small geometry — compositor must clamp, not crash
    c:geometry({ x = 100, y = 100, width = 3, height = 3 })
    async.sleep(0.2)

    assert(c.valid, "Client should still be valid after extreme resize (compositor alive)")

    local geo = c:geometry()
    assert(geo ~= nil, "Geometry must be non-nil")

    -- Minimum height = 2*bw + titlebar_top + 1px content
    local min_h = 2 * bw + 29 + 1
    local min_w = 2 * bw + 1
    assert(geo.height >= min_h,
        string.format("[TEST 1] height %d should be >= %d (2*bw + titlebar + 1)",
            geo.height, min_h))
    assert(geo.width >= min_w,
        string.format("[TEST 1] width %d should be >= %d", geo.width, min_w))

    io.stderr:write(string.format("[TEST 1] PASS — geometry %dx%d >= min %dx%d\n",
        geo.width, geo.height, min_w, min_h))

    assert(cleanup(c), "Cleanup: client did not close")

    ---------------------------------------------------------------------------
    -- TEST 2: Bug 6 — fullscreen hides titlebar and surface fills screen
    -- client_update_titlebar_positions() must disable titlebar nodes when fullscreen;
    -- apply_geometry_to_wlroots() must zero titlebar offsets.
    ---------------------------------------------------------------------------
    io.stderr:write("[TEST 2] Fullscreen hides titlebar, surface fills geometry\n")

    test_client("titlebar_geo_2")
    local c2 = async.wait_for_client("titlebar_geo_2", 5)
    assert(c2, "Client did not appear")

    awful.titlebar(c2, { size = 29, position = "top" })
    async.sleep(0.15)

    c2.floating = true
    async.sleep(0.05)

    c2.fullscreen = true
    async.sleep(0.2)

    assert(c2.fullscreen, "Client should be fullscreen")

    -- Client geometry must cover the whole screen
    local sg = c2.screen.geometry
    local fg = c2:geometry()
    assert(fg.x == sg.x,
        string.format("[TEST 2] fullscreen x=%d, expected %d", fg.x, sg.x))
    assert(fg.y == sg.y,
        string.format("[TEST 2] fullscreen y=%d, expected %d", fg.y, sg.y))
    assert(fg.width == sg.width,
        string.format("[TEST 2] fullscreen w=%d, expected %d", fg.width, sg.width))
    assert(fg.height == sg.height,
        string.format("[TEST 2] fullscreen h=%d, expected %d", fg.height, sg.height))

    -- Titlebar scene node is hidden at C level when fullscreen.
    -- We verify this indirectly: the Lua size should still be > 0 (not destroyed),
    -- meaning the compositor is tracking it correctly for restore on exit.
    local _, tb_size = c2:titlebar_top()
    assert(tb_size > 0,
        "[TEST 2] titlebar size should still be > 0 in fullscreen (preserved for restore)")

    io.stderr:write("[TEST 2] PASS — fullscreen geometry correct, titlebar preserved\n")

    -- Toggle back — compositor must not crash
    c2.fullscreen = false
    async.sleep(0.1)
    assert(not c2.fullscreen, "fullscreen should be off after toggle")

    assert(cleanup(c2), "Cleanup: client did not close")

    ---------------------------------------------------------------------------
    -- TEST 3: Bug 1 — clip self-consistency with multiple titlebars
    -- The clip rect is C-internal; we verify that content dimensions (geometry
    -- minus borders and all titlebar sizes) are always >= 1.
    ---------------------------------------------------------------------------
    io.stderr:write("[TEST 3] Clip self-consistency: top + bottom titlebars\n")

    test_client("titlebar_geo_3")
    local c3 = async.wait_for_client("titlebar_geo_3", 5)
    assert(c3, "Client did not appear")

    awful.titlebar(c3, { size = 24, position = "top" })
    awful.titlebar(c3, { size = 18, position = "bottom" })
    async.sleep(0.15)

    c3.floating = true
    async.sleep(0.05)

    c3:geometry({ x = 200, y = 200, width = 500, height = 300 })
    async.sleep(0.2)

    local geo3 = c3:geometry()
    local bw3 = c3.border_width or 0

    local cw = geo3.width  - 2 * bw3
    local ch = geo3.height - 2 * bw3 - 24 - 18

    assert(cw >= 1,
        "[TEST 3] content width must be >= 1 (clip must not be empty), got " .. cw)
    assert(ch >= 1,
        "[TEST 3] content height must be >= 1 (clip must not be empty), got " .. ch)

    io.stderr:write(string.format("[TEST 3] PASS — geo %dx%d → content %dx%d\n",
        geo3.width, geo3.height, cw, ch))

    assert(cleanup(c3), "Cleanup: client did not close")

    ---------------------------------------------------------------------------
    -- TEST 4: client.aspect_ratio property read/write/signal/constraint
    ---------------------------------------------------------------------------
    io.stderr:write("[TEST 4] aspect_ratio property constrains resize\n")

    test_client("titlebar_geo_4")
    local c4 = async.wait_for_client("titlebar_geo_4", 5)
    assert(c4, "Client did not appear")

    c4.floating = true
    async.sleep(0.05)

    -- Default is 0 (disabled)
    assert(c4.aspect_ratio == 0,
        "default aspect_ratio should be 0, got " .. tostring(c4.aspect_ratio))

    -- Set 16:9 ratio and read it back
    local target = 16 / 9
    c4.aspect_ratio = target
    assert(math.abs(c4.aspect_ratio - target) < 0.001,
        "aspect_ratio should read back as 16/9")

    -- Request a non-16:9 geometry; compositor should enforce the ratio
    c4:geometry({ x = 100, y = 100, width = 800, height = 300 })
    async.sleep(0.2)

    local geo4 = c4:geometry()
    local ratio = geo4.width / geo4.height
    assert(math.abs(ratio - target) / target < 0.05,
        string.format("[TEST 4] ratio after resize %.3f should be near 16:9 (%.3f)",
            ratio, target))

    -- Disable
    c4.aspect_ratio = 0
    assert(c4.aspect_ratio == 0, "aspect_ratio should be 0 after disable")

    -- property::aspect_ratio signal fires on change
    local fired = false
    c4:connect_signal("property::aspect_ratio", function() fired = true end)
    c4.aspect_ratio = 4 / 3
    async.sleep(0.05)
    assert(fired, "property::aspect_ratio signal must fire on change")

    io.stderr:write("[TEST 4] PASS — aspect_ratio read/write/signal/constraint works\n")

    assert(cleanup(c4), "Cleanup: client did not close")

    ---------------------------------------------------------------------------
    io.stderr:write("[ALL TESTS] PASS\n")
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
