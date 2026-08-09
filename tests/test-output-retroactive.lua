---------------------------------------------------------------------------
-- Tests for output "added::connected" retroactive signal delivery:
--   1. Create an output, then connect handler afterward
--   2. Verify handler fires retroactively for all existing outputs
--   3. Verify handler receives correct output properties
--   4. Verify hotplug still works (new output after handler connected)
--   5. Verify a second handler also gets retroactive delivery
--
-- _test_add_output/_test_remove_output are synchronous (wlroots emits
-- new_output/destroy inline), so these steps assert directly.
---------------------------------------------------------------------------

local runner = require("_runner")

print("TEST: Starting output-retroactive test")

local out1_name = nil
local out2_name = nil
local retroactive_outputs = {}
local post_connect_outputs = {}
local handler_connected = false

local steps = {
    -- Step 1: Create an output BEFORE connecting the handler
    function()
        print("TEST: Step 1 - Create output before handler is connected")
        out1_name = assert(awesome._test_add_output(800, 600),
            "_test_add_output should return a name")
        local o = assert(output.get_by_name(out1_name),
            "no output named " .. out1_name)
        assert(o.valid, "output should be valid")
        assert(o.screen, "output should have a screen")
        print("TEST:   created output: " .. out1_name)
        return true
    end,

    -- Step 2: Connect handler AFTER output exists - should fire retroactively
    function()
        print("TEST: Step 2 - Connect handler after output exists")
        local expected_count = output.count()

        output.connect_signal("added", function(o)
            if not handler_connected then
                -- Still inside connect_signal call = retroactive delivery
                table.insert(retroactive_outputs, {
                    name = o.name,
                    valid = o.valid,
                    screen = o.screen,
                })
            else
                -- After connect_signal returned = normal hotplug
                table.insert(post_connect_outputs, {
                    name = o.name,
                    valid = o.valid,
                })
            end
        end)
        handler_connected = true

        -- Retroactive delivery should fire for ALL existing outputs
        assert(#retroactive_outputs == expected_count,
            "handler should fire retroactively for all " .. expected_count
            .. " existing outputs, got " .. #retroactive_outputs)
        print("TEST:   retroactive delivery fired for "
            .. #retroactive_outputs .. " outputs")
        return true
    end,

    -- Step 3: Verify our output was among the retroactive deliveries
    function()
        print("TEST: Step 3 - Verify output in retroactive deliveries")
        local found = false
        local out1_screen = output.get_by_name(out1_name).screen
        for _, info in ipairs(retroactive_outputs) do
            if info.name == out1_name then
                found = true
                assert(info.valid == true,
                    "retroactive output should be valid")
                assert(info.screen == out1_screen,
                    "retroactive output should reference its screen")
                print("TEST:   found " .. info.name
                    .. " valid=" .. tostring(info.valid) .. " screen=OK")
            end
        end
        assert(found,
            "output " .. out1_name
            .. " should be among retroactive deliveries")
        return true
    end,

    -- Step 4: Hotplug - add new output AFTER handler connected
    function()
        print("TEST: Step 4 - Hotplug: add new output after handler connected")
        out2_name = assert(awesome._test_add_output(400, 300),
            "second _test_add_output should succeed")

        local delivered = nil
        for _, info in ipairs(post_connect_outputs) do
            if info.name == out2_name then delivered = info end
        end
        assert(delivered, "handler should fire for hotplugged output")
        assert(delivered.valid == true,
            "hotplugged output should be valid")
        print("TEST:   hotplug delivery OK")

        assert(awesome._test_remove_output(out2_name),
            "_test_remove_output failed for " .. out2_name)
        return true
    end,

    -- Step 5: Second handler also gets retroactive delivery
    function()
        print("TEST: Step 5 - Second handler gets retroactive delivery")
        local second_fired = {}
        output.connect_signal("added", function(o)
            table.insert(second_fired, o.name)
        end)

        -- Should fire for all currently existing outputs
        assert(#second_fired == output.count(),
            "second handler should get retroactive delivery for "
            .. output.count() .. " outputs, got " .. #second_fired)
        print("TEST:   second handler fired for "
            .. #second_fired .. " output(s)")
        return true
    end,

    -- Step 6: Cleanup
    function()
        assert(awesome._test_remove_output(out1_name),
            "_test_remove_output failed for " .. out1_name)
        print("TEST:   cleanup done")
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
