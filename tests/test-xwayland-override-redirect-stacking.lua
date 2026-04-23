---------------------------------------------------------------------------
--- Test: XWayland override_redirect popup stacking (issue #415)
--
-- Bug: Override_redirect X11 surfaces (Wine menus, Steam popups, Qt
-- tooltips) appeared BELOW their parent window instead of above it.
--
-- Root cause: stack_refresh() ran unmanaged clients through
-- client_layer_translator(), which returned WINDOW_LAYER_NORMAL (LyrTile)
-- by default because override_redirect clients have no stacking
-- attributes. That reparenting dropped popups below floating parents.
--
-- Fix: mapnotify() places override_redirect clients in LyrOverlay;
-- stack_refresh() skips unmanaged clients entirely so the placement
-- survives.
--
-- This test:
--  1. Spawns a managed X11 client and makes it floating.
--  2. Spawns an override_redirect X11 window via a ctypes helper.
--  3. Asserts the popup's scene-graph parent is LyrOverlay right after map.
--  4. Toggles parent properties (ontop/above/floating/fullscreen), forcing
--     stack_refresh() cycles.
--  5. Asserts the popup is STILL in LyrOverlay after each cycle. Without
--     the fix the popup would read as "tile" after the first cycle.
---------------------------------------------------------------------------

local runner = require("_runner")
local x11_client = require("_x11_client")
local utils = require("_utils")

if utils.is_headless() then
    io.stderr:write("SKIP: override_redirect test requires visual mode (HEADLESS=0)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

if not x11_client.is_available() then
    io.stderr:write("SKIP: no X11 application available (install xterm)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local python3_check = os.execute("which python3 >/dev/null 2>&1")
if not python3_check then
    io.stderr:write("SKIP: python3 not available for X11 helper\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local awful = require("awful")

local PARENT_CLASS = "or_stacking_parent"
local POPUP_CLASS  = "or_stacking_popup"

-- Resolve helper script path (same pattern as test-xwayland-remap.lua)
local script_dir = debug.getinfo(1, "S").source:match("@(.*/)")
local helper_path = script_dir .. "helpers/x11_override_redirect.py"

local parent_client     = nil
local popup_pid         = nil
local popup_client      = nil
local pre_spawn_windows = {}

-- Track parent via request::manage (managed clients emit it).
client.connect_signal("request::manage", function(c)
    if x11_client.is_xwayland(c) and
       (c.class == PARENT_CLASS or c.class == PARENT_CLASS:lower()) then
        parent_client = c
        io.stderr:write(string.format(
            "[TEST] Managed parent client appeared: class=%s\n", tostring(c.class)
        ))
    end
end)

-- Override_redirect clients do NOT fire request::manage and
-- property_update_xwayland_properties() is skipped for them in
-- mapnotify(), so c.class is never populated. Identify the popup
-- instead by diffing client.get() against a snapshot of pre-existing
-- X11 window IDs taken just before spawning the helper.
local function snapshot_x11_windows()
    local set = {}
    for _, c in ipairs(client.get()) do
        if x11_client.is_xwayland(c) and c.window and c.window > 0 then
            set[c.window] = true
        end
    end
    return set
end

local function find_popup()
    for _, c in ipairs(client.get()) do
        if x11_client.is_xwayland(c) and
           c.window and c.window > 0 and
           not pre_spawn_windows[c.window] then
            return c
        end
    end
    return nil
end

local function assert_popup_in_overlay(popup, context)
    assert(popup.valid, context .. ": popup should be valid")
    local layer = popup._scene_layer
    assert(layer == "overlay", string.format(
        "%s: expected popup in LyrOverlay, got %q (bug #415 regression)",
        context, tostring(layer)
    ))
    io.stderr:write(string.format(
        "[TEST] PASS %s: popup is in %s layer\n", context, layer
    ))
end

local steps = {
    -- Step 1: Spawn managed X11 parent client
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning managed X11 parent client...\n")
            x11_client(PARENT_CLASS)
        end

        if parent_client then return true end

        if count > 80 then
            error("Managed X11 parent client did not appear within timeout")
        end
        return nil
    end,

    -- Step 2: Make parent floating (so it lives in LyrFloat, the buggy
    -- regression point would surface popups below it).
    function()
        parent_client.floating = true
        assert(parent_client.floating, "Parent should be floating")
        io.stderr:write("[TEST] Parent set floating\n")
        return true
    end,

    -- Step 3: Spawn the override_redirect popup. Snapshot existing X11
    -- window IDs first so we can diff for the new one.
    function(count)
        if count == 1 then
            pre_spawn_windows = snapshot_x11_windows()
            io.stderr:write("[TEST] Spawning override_redirect popup helper...\n")
            popup_pid = awful.spawn("python3 " .. helper_path ..
                " " .. POPUP_CLASS .. " 50 50 200 150")
            io.stderr:write(string.format("[TEST] Popup helper PID: %s\n",
                tostring(popup_pid)))

            if not popup_pid or type(popup_pid) ~= "number" or popup_pid <= 0 then
                error("Failed to spawn override_redirect helper: " ..
                    tostring(popup_pid))
            end
        end

        popup_client = find_popup()
        if popup_client then
            io.stderr:write(string.format(
                "[TEST] Override_redirect popup appeared: window=%d type=%s\n",
                popup_client.window, tostring(popup_client.type)
            ))
            return true
        end
        return nil
    end,

    -- Step 4: Immediately after map, popup must be in LyrOverlay.
    -- This catches the mapnotify placement bug (LyrFloat in the old code).
    function()
        assert(popup_client, "Popup should be findable after map")
        assert_popup_in_overlay(popup_client, "after-map")
        return true
    end,

    -- Step 5: Trigger stack_refresh() cycles via parent property toggles.
    -- Pre-fix: the first toggle would reparent the popup to LyrTile.
    function()
        assert(popup_client and popup_client.valid, "Popup must still be valid")

        -- floating starts true (set in step 2), so toggle false->true; the
        -- others start false so toggle true->false. Every pair crosses a
        -- stack_refresh() boundary, which is what we want to stress.
        local toggles = {
            { prop = "ontop",      sequence = { true, false } },
            { prop = "above",      sequence = { true, false } },
            { prop = "floating",   sequence = { false, true } },
            { prop = "fullscreen", sequence = { true, false } },
        }
        for _, t in ipairs(toggles) do
            io.stderr:write("[TEST] Toggling parent " .. t.prop .. "...\n")
            for _, value in ipairs(t.sequence) do
                parent_client[t.prop] = value
                assert_popup_in_overlay(popup_client,
                    string.format("after-%s-%s", t.prop, tostring(value)))
            end
        end

        return true
    end,

    -- Step 6: Cleanup. Kill popup helper first (unmanaged, no close path),
    -- then let the parent's kill proceed.
    function(count)
        if count == 1 then
            if popup_pid then
                os.execute("kill " .. popup_pid .. " 2>/dev/null")
            end
            os.execute("pkill -f x11_override_redirect.py 2>/dev/null")

            if parent_client and parent_client.valid then
                parent_client:kill()
            end
        end

        if count > 10 then
            io.stderr:write("[TEST] All override_redirect stacking assertions PASSED\n")
            io.stderr:write("Test finished successfully.\n")
            awesome.quit()
            return true
        end
        return nil
    end,
}

-- Spawning python3 and waiting for the popup to show up in client.get()
-- can take longer than the default 2 seconds per step under load.
runner.run_steps(steps, { kill_clients = false, wait_per_step = 10 })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
