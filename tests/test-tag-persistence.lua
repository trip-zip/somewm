---------------------------------------------------------------------------
-- Tests tag persistence across monitor hotplug:
--   1. Two screens exist with tags
--   2. Client spawned on screen 2 is tagged there
--   3. Disabling output 2 saves tags and migrates client to screen 1
--   4. Re-enabling output 2 restores saved tags with original names
--   5. Client moves back to restored tag on screen 2
--
-- Run with: WLR_WL_OUTPUTS=2 make test-one TEST=tests/test-tag-persistence.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

-- This test requires 2 outputs
if screen.count() < 2 then
    io.stderr:write("SKIP: test-tag-persistence requires WLR_WL_OUTPUTS=2\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

-- Skip if no terminal for client spawning
if not test_client.is_available() then
    io.stderr:write("SKIP: no terminal available for client spawning\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

print("TEST: tag-persistence: screen.count()=" .. screen.count())

-- Record the output name of screen 2 for verification
local screen2_output_name = screen[2].output.name
print("TEST: screen 2 output name: " .. screen2_output_name)

-- Tag persistence handlers (mirrors somewmrc.lua logic)
local _saved_tags = {}

tag.connect_signal("request::screen", function(t, reason)
    if reason ~= "removed" then return end
    local s = t.screen
    local output_name = s and s.output and s.output.name
    if not output_name then return end
    if not _saved_tags[output_name] then
        _saved_tags[output_name] = {}
    end
    table.insert(_saved_tags[output_name], {
        name = t.name,
        selected = t.selected,
        layout = t.layout,
        master_width_factor = t.master_width_factor,
        master_count = t.master_count,
        gap = t.gap,
        clients = t:clients(),
    })
end)

-- Restore handler: fires after test rc.lua's connect_for_each_screen handler
-- which creates a default "test" tag via the "added" signal.
-- request::desktop_decoration fires after "added", so we can replace the
-- auto-created tags with restored ones.
screen.connect_signal("request::desktop_decoration", function(s)
    local output_name = s.output and s.output.name
    local restore = output_name and _saved_tags[output_name]
    if not restore then return end
    _saved_tags[output_name] = nil
    -- Delete auto-created tags from test rc.lua
    for _, t in ipairs(s.tags) do
        t:delete()
    end
    -- Restore saved tags
    for _, td in ipairs(restore) do
        local t = awful.tag.add(td.name, {
            screen = s,
            layout = td.layout,
            master_width_factor = td.master_width_factor,
            master_count = td.master_count,
            gap = td.gap,
            selected = td.selected,
        })
        for _, c in ipairs(td.clients) do
            if c.valid then
                c:move_to_screen(s)
                c:tags({t})
            end
        end
    end
end)

local my_client = nil

local steps = {
    -- Step 1: Verify 2 screens exist with tags
    function()
        print("TEST: Step 1 - Verify 2 screens with tags")
        assert(screen.count() == 2,
            "Expected 2 screens, got " .. screen.count())
        for s in screen do
            assert(#s.tags > 0,
                "Screen " .. s.index .. " has no tags")
            print("TEST:   screen " .. s.index .. ": " .. #s.tags .. " tags"
                .. ", output=" .. s.output.name)
        end
        return true
    end,

    -- Step 2: Spawn a client on screen 2
    function(count)
        if count == 1 then
            test_client("persist_test", "PersistClient")
        end
        my_client = utils.find_client_by_class("persist_test")
        if not my_client then return end

        -- Move client to screen 2
        my_client:move_to_screen(screen[2])
        local s2_tag = screen[2].tags[1]
        if s2_tag then
            my_client:tags({s2_tag})
        end
        print("TEST: Step 2 - Client spawned on screen "
            .. tostring(my_client.screen and my_client.screen.index))
        return true
    end,

    -- Step 3: Verify client is on screen 2
    function()
        print("TEST: Step 3 - Verify client on screen 2")
        assert(my_client.valid, "Client should be valid")
        assert(my_client.screen == screen[2],
            "Client should be on screen 2, got screen "
            .. tostring(my_client.screen and my_client.screen.index))
        local tags = my_client:tags()
        assert(#tags > 0, "Client should have tags")
        print("TEST:   client on screen " .. my_client.screen.index
            .. ", tag=" .. tags[1].name)
        return true
    end,

    -- Step 4: Disable output 2 (simulates monitor disconnect)
    function()
        print("TEST: Step 4 - Disable output 2")
        local o = output[2]
        assert(o, "output[2] should exist")
        print("TEST:   disabling output: " .. o.name)
        o.enabled = false
        return true
    end,

    -- Step 5: Wait for screen count to drop, verify client migrated
    function()
        if screen.count() > 1 then return end
        print("TEST: Step 5 - Screen 2 removed, verifying state")
        assert(screen.count() == 1,
            "Expected 1 screen after disable, got " .. screen.count())

        -- Client should have migrated to screen 1
        assert(my_client.valid, "Client should still be valid")
        assert(my_client.screen == screen[1],
            "Client should have migrated to screen 1, got screen "
            .. tostring(my_client.screen and my_client.screen.index))
        print("TEST:   client migrated to screen " .. my_client.screen.index)

        -- Saved tags should exist for the disconnected output
        assert(_saved_tags[screen2_output_name] ~= nil,
            "Tags should be saved for output " .. screen2_output_name)
        print("TEST:   saved " .. #_saved_tags[screen2_output_name]
            .. " tags for " .. screen2_output_name)
        return true
    end,

    -- Step 6: Re-enable output 2 (simulates monitor reconnect)
    function()
        print("TEST: Step 6 - Re-enable output 2")
        local o = output[2]
        assert(o, "output[2] should still exist")
        o.enabled = true
        return true
    end,

    -- Step 7: Wait for screen 2 to reappear, verify tags restored
    function()
        if screen.count() < 2 then return end
        print("TEST: Step 7 - Screen 2 restored, verifying tags")
        assert(screen.count() == 2,
            "Expected 2 screens after re-enable, got " .. screen.count())

        -- Find the screen with the original output name
        local restored_screen = nil
        for s in screen do
            if s.output and s.output.name == screen2_output_name then
                restored_screen = s
                break
            end
        end
        assert(restored_screen,
            "Screen with output " .. screen2_output_name .. " should exist")

        -- Tags should be restored with original names
        assert(#restored_screen.tags > 0,
            "Restored screen should have tags")
        print("TEST:   restored screen has " .. #restored_screen.tags .. " tags")
        for i, t in ipairs(restored_screen.tags) do
            print("TEST:   tag " .. i .. ": " .. t.name)
        end

        -- The original test tag name should be present
        local found_original = false
        for _, t in ipairs(restored_screen.tags) do
            if t.name == "test" then
                found_original = true
                break
            end
        end
        assert(found_original,
            "Restored tags should include original 'test' tag")

        -- Saved tags should be consumed
        assert(_saved_tags[screen2_output_name] == nil,
            "Saved tags should be consumed after restore")
        return true
    end,

    -- Step 8: Verify client moved back to screen 2
    function()
        print("TEST: Step 8 - Verify client restored to screen 2")
        assert(my_client.valid, "Client should still be valid")

        -- Find the restored screen
        local restored_screen = nil
        for s in screen do
            if s.output and s.output.name == screen2_output_name then
                restored_screen = s
                break
            end
        end

        assert(my_client.screen == restored_screen,
            "Client should be back on restored screen, got screen "
            .. tostring(my_client.screen and my_client.screen.index))

        local tags = my_client:tags()
        assert(#tags > 0, "Client should have tags on restored screen")
        print("TEST:   client on screen " .. my_client.screen.index
            .. ", tag=" .. tags[1].name)
        return true
    end,

    -- Step 9: Cleanup
    function(count)
        if count == 1 then
            my_client:kill()
        end
        return #client.get() == 0
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
