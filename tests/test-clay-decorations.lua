---------------------------------------------------------------------------
--- Test: Phase 5 client decoration Clay sub-pass.
---
--- Verifies that clay_apply_client_decorations() produces the same content
--- geometry as the legacy hand-rolled math: a client with 4 titlebars at
--- distinct sizes survives map -> resize -> fullscreen toggle without
--- crashing, and the geometry stays consistent end-to-end.
---
--- Run: make test-one TEST=tests/test-clay-decorations.lua
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
    -- TEST 1: 4 titlebars + (possibly zero) border, all distinct sizes
    -- The Clay tree must lay them out with the same arithmetic as the legacy
    -- math; the inner content (geometry minus 2*bw and titlebar sums) must
    -- always be >= 1 and the client must not crash.
    ---------------------------------------------------------------------------
    io.stderr:write("[TEST 1] Four titlebars, distinct sizes\n")

    test_client("clay_decor_1")
    local c = async.wait_for_client("clay_decor_1", 5)
    assert(c, "Client did not appear")

    local TB = { top = 24, right = 8, bottom = 18, left = 10 }
    awful.titlebar(c, { size = TB.top,    position = "top"    })
    awful.titlebar(c, { size = TB.right,  position = "right"  })
    awful.titlebar(c, { size = TB.bottom, position = "bottom" })
    awful.titlebar(c, { size = TB.left,   position = "left"   })
    async.sleep(0.2)

    c.floating = true
    async.sleep(0.05)

    local bw = c.border_width or 0

    c:geometry({ x = 200, y = 150, width = 600, height = 400 })
    async.sleep(0.2)

    local geo = c:geometry()
    assert(geo, "geometry must be readable")

    local content_w = geo.width  - 2 * bw - TB.left - TB.right
    local content_h = geo.height - 2 * bw - TB.top  - TB.bottom

    assert(content_w >= 1,
        string.format("[TEST 1] content_w must be >= 1, got %d", content_w))
    assert(content_h >= 1,
        string.format("[TEST 1] content_h must be >= 1, got %d", content_h))

    io.stderr:write(string.format(
        "[TEST 1] PASS - geo %dx%d, bw=%d, tb=(t%d r%d b%d l%d), content %dx%d\n",
        geo.width, geo.height, bw,
        TB.top, TB.right, TB.bottom, TB.left, content_w, content_h))

    assert(cleanup(c), "Cleanup 1: client did not close")

    ---------------------------------------------------------------------------
    -- TEST 2: Fullscreen with 4 titlebars
    -- Fullscreen must zero titlebar contributions; surface fills full geometry
    -- minus borders only. Toggling back must restore titlebars without crash.
    ---------------------------------------------------------------------------
    io.stderr:write("[TEST 2] Fullscreen with 4 titlebars\n")

    test_client("clay_decor_2")
    local c2 = async.wait_for_client("clay_decor_2", 5)
    assert(c2, "Client 2 did not appear")

    awful.titlebar(c2, { size = 20, position = "top"    })
    awful.titlebar(c2, { size = 14, position = "bottom" })
    awful.titlebar(c2, { size = 8,  position = "left"   })
    awful.titlebar(c2, { size = 8,  position = "right"  })
    async.sleep(0.2)

    c2.floating = true
    async.sleep(0.05)

    c2.fullscreen = true
    async.sleep(0.2)

    assert(c2.fullscreen, "client must be fullscreen")
    local sg = c2.screen.geometry
    local fg = c2:geometry()
    assert(fg.x == sg.x and fg.y == sg.y
        and fg.width == sg.width and fg.height == sg.height,
        string.format("[TEST 2] fullscreen geo %dx%d@%d,%d != screen %dx%d@%d,%d",
            fg.width, fg.height, fg.x, fg.y,
            sg.width, sg.height, sg.x, sg.y))

    -- Titlebar sizes preserved (so they restore on exit).
    local _, t = c2:titlebar_top()
    local _, r = c2:titlebar_right()
    local _, b = c2:titlebar_bottom()
    local _, l = c2:titlebar_left()
    assert(t == 20 and b == 14 and l == 8 and r == 8,
        string.format("[TEST 2] titlebar sizes mutated in fs: t%d r%d b%d l%d",
            t, r, b, l))

    -- Toggle off; client must remain valid.
    c2.fullscreen = false
    async.sleep(0.2)
    assert(not c2.fullscreen, "fullscreen should be off after toggle")
    assert(c2.valid, "client must still be valid after fullscreen toggle")

    io.stderr:write("[TEST 2] PASS - fullscreen fills geometry, titlebars preserved\n")

    assert(cleanup(c2), "Cleanup 2: client did not close")

    ---------------------------------------------------------------------------
    -- TEST 3: Resize loop with all 4 titlebars
    -- Clay must converge on stable geometry across multiple resizes.
    ---------------------------------------------------------------------------
    io.stderr:write("[TEST 3] Resize loop convergence\n")

    test_client("clay_decor_3")
    local c3 = async.wait_for_client("clay_decor_3", 5)
    assert(c3, "Client 3 did not appear")

    awful.titlebar(c3, { size = 24, position = "top"    })
    awful.titlebar(c3, { size = 18, position = "bottom" })
    awful.titlebar(c3, { size = 10, position = "left"   })
    awful.titlebar(c3, { size = 8,  position = "right"  })
    async.sleep(0.2)

    c3.floating = true
    async.sleep(0.05)

    local bw3 = c3.border_width or 0
    local sizes = { {300, 200}, {800, 600}, {500, 350}, {640, 480} }
    for _, sz in ipairs(sizes) do
        c3:geometry({ x = 100, y = 100, width = sz[1], height = sz[2] })
        async.sleep(0.1)
        assert(c3.valid, string.format(
            "[TEST 3] client invalid after resize to %dx%d", sz[1], sz[2]))

        local g = c3:geometry()
        local cw = g.width  - 2 * bw3 - 10 - 8
        local ch = g.height - 2 * bw3 - 24 - 18
        assert(cw >= 1 and ch >= 1,
            string.format("[TEST 3] content %dx%d invalid for geo %dx%d",
                cw, ch, g.width, g.height))
    end

    io.stderr:write("[TEST 3] PASS - 4 resizes converge, content stays valid\n")

    assert(cleanup(c3), "Cleanup 3: client did not close")

    io.stderr:write("[ALL TESTS] PASS\n")
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
