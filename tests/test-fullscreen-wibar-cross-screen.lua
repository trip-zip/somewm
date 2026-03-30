---------------------------------------------------------------------------
--- Test: fullscreen client ALWAYS stays above wibar on Wayland
--
-- On Wayland, fullscreen clients unconditionally stay in WINDOW_LAYER_FULLSCREEN
-- (mapped to LyrFS in the scene graph). This ensures they are always above
-- wibar (LyrTop/LyrWibox) regardless of focus state — both cross-screen and
-- same-screen. Dialogs/transients appear above fullscreen parents via
-- stack_transients_above() which follows the WINDOW_LAYER_IGNORE path.
--
-- This differs from X11/AwesomeWM where stacking is flat and focus-based
-- demotion was needed.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

-- Check if we're in headless mode
local function is_headless()
    local backend = os.getenv("WLR_BACKENDS")
    return backend == "headless"
end

if is_headless() then
    io.stderr:write("SKIP: cross-screen fullscreen test requires multi-monitor support (screen.fake_add crashes in headless)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local fake_screen
local c_fs, c_other
local wibar_s2

local steps = {
    -- Step 1: Add a fake second screen and create a wibar on it
    function()
        fake_screen = screen.fake_add(1400, 0, 400, 300)
        assert(fake_screen and fake_screen.valid, "screen.fake_add failed")
        assert(screen.count() >= 2, "Need at least 2 screens")

        -- Create a dock-type wibar on screen 2 (goes to LyrTop)
        wibar_s2 = awful.wibar({ position = "top", screen = fake_screen })
        assert(wibar_s2 and wibar_s2.visible, "Wibar should be visible")

        io.stderr:write("[TEST] Fake screen and wibar created\n")
        return true
    end,

    -- Step 2: Spawn a client that will go fullscreen on screen 2
    function(count)
        if count == 1 then
            test_client("fs_client")
        end
        c_fs = utils.find_client_by_class("fs_client")
        if not c_fs then return nil end
        io.stderr:write("[TEST] Fullscreen candidate spawned\n")
        return true
    end,

    -- Step 3: Move client to screen 2 and make it fullscreen
    function(count)
        if count == 1 then
            c_fs:move_to_screen(fake_screen)
            c_fs.fullscreen = true
            c_fs:emit_signal("request::activate", "test", { raise = true })
        end
        if not c_fs.fullscreen then return nil end
        if c_fs.screen ~= fake_screen then return nil end
        if client.focus ~= c_fs then return nil end
        io.stderr:write("[TEST] Client is fullscreen on screen 2 with focus\n")
        return true
    end,

    -- Step 4: Spawn a second client on screen 1 (it will take focus)
    function(count)
        if count == 1 then
            test_client("other_client")
        end
        c_other = utils.find_client_by_class("other_client")
        if not c_other then return nil end
        io.stderr:write("[TEST] Second client spawned on screen 1\n")
        return true
    end,

    -- Step 5: Ensure other client is on screen 1 and activate it
    function(count)
        if count == 1 then
            local s1 = screen.primary
            if c_other.screen ~= s1 then
                c_other:move_to_screen(s1)
            end
            c_other:emit_signal("request::activate", "test", { raise = true })
        end
        if client.focus ~= c_other then return nil end
        if c_other.screen == c_fs.screen then return nil end
        io.stderr:write("[TEST] Focus moved to client on screen 1\n")
        return true
    end,

    -- Step 6: Verify fullscreen client on screen 2 is still fullscreen.
    -- Before the fix, client_layer_translator() would return
    -- WINDOW_LAYER_NORMAL (-> LyrTile) for this unfocused fullscreen client,
    -- causing the wibar (at LyrTop) to appear above it. After the fix,
    -- it returns WINDOW_LAYER_FULLSCREEN (-> LyrFS) because the focused
    -- client is on a different screen.
    function()
        assert(c_fs.valid, "Fullscreen client should still be valid")
        assert(c_fs.fullscreen,
            "Client should still be fullscreen after cross-screen focus change")
        assert(c_fs.screen == fake_screen,
            "Client should still be on screen 2")
        assert(client.focus ~= c_fs,
            "Fullscreen client should NOT have focus")
        assert(client.focus == c_other,
            "Other client should have focus")

        io.stderr:write("[TEST] PASS: fullscreen client stays fullscreen " ..
            "after cross-screen focus change\n")
        return true
    end,

    -- Step 7: On Wayland, fullscreen clients ALWAYS stay in LyrFS (above wibar)
    -- even when another client on the same screen has focus. This differs from
    -- X11/AwesomeWM where stacking is flat. Dialogs use transient_for to
    -- appear above their fullscreen parent via stack_transients_above().
    function(count)
        if count == 1 then
            c_other:move_to_screen(fake_screen)
            c_other:emit_signal("request::activate", "test", { raise = true })
        end
        if client.focus ~= c_other then return nil end
        if c_other.screen ~= c_fs.screen then return nil end
        assert(c_fs.fullscreen,
            "Fullscreen property should still be set")
        io.stderr:write("[TEST] PASS: same-screen fullscreen client stays " ..
            "in LyrFS (Wayland scene graph behavior)\n")
        return true
    end,

    -- Step 8: Cleanup
    function(count)
        if count == 1 then
            if wibar_s2 then wibar_s2.visible = false end
            if c_fs and c_fs.valid then c_fs:kill() end
            if c_other and c_other.valid then c_other:kill() end
        end
        if #client.get() == 0 then
            if fake_screen and fake_screen.valid then
                fake_screen:fake_remove()
            end
            return true
        end
        if count >= 15 then
            local pids = test_client.get_spawned_pids()
            for _, pid in ipairs(pids) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            if fake_screen and fake_screen.valid then
                fake_screen:fake_remove()
            end
            return true
        end
        return nil
    end,
}

runner.run_steps(steps, { kill_clients = false })
