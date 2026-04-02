---------------------------------------------------------------------------
-- Tests for output "added::connected" retroactive signal delivery:
--   1. Create an output (via fake_add), then connect handler afterward
--   2. Verify handler fires retroactively for all existing outputs
--   3. Verify handler receives correct output properties
--   4. Verify hotplug still works (new output after handler connected)
--   5. Verify a second handler also gets retroactive delivery
---------------------------------------------------------------------------

local runner = require("_runner")

print("TEST: Starting output-retroactive test")

local fake_screen1 = nil
local retroactive_outputs = {}
local post_connect_outputs = {}
local handler_connected = false

local steps = {
    -- Step 1: Create a fake screen BEFORE connecting the handler
    function()
        print("TEST: Step 1 - Create output before handler is connected")
        fake_screen1 = screen.fake_add(0, 0, 800, 600)
        assert(fake_screen1, "fake_add should return a screen")
        assert(fake_screen1.output, "fake screen should have an output")
        assert(fake_screen1.output.valid, "output should be valid")
        print("TEST:   created output: " .. fake_screen1.output.name)
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

    -- Step 3: Verify our fake output was among the retroactive deliveries
    function()
        print("TEST: Step 3 - Verify fake output in retroactive deliveries")
        local found = false
        for _, info in ipairs(retroactive_outputs) do
            if info.name == fake_screen1.output.name then
                found = true
                assert(info.valid == true,
                    "retroactive output should be valid")
                assert(info.screen == fake_screen1,
                    "retroactive output should reference its screen")
                print("TEST:   found " .. info.name
                    .. " valid=" .. tostring(info.valid) .. " screen=OK")
            end
        end
        assert(found,
            "fake output " .. fake_screen1.output.name
            .. " should be among retroactive deliveries")
        return true
    end,

    -- Step 4: Hotplug - add new screen AFTER handler connected
    function()
        print("TEST: Step 4 - Hotplug: add new output after handler connected")
        local before = #post_connect_outputs
        local fake_screen2 = screen.fake_add(800, 0, 400, 300)
        assert(fake_screen2, "second fake_add should succeed")

        local new_deliveries = #post_connect_outputs - before
        assert(new_deliveries == 1,
            "handler should fire once for hotplugged output, got "
            .. new_deliveries)
        assert(post_connect_outputs[#post_connect_outputs].valid == true,
            "hotplugged output should be valid")
        print("TEST:   hotplug delivery OK")

        -- Cleanup
        fake_screen2:fake_remove()
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
        print("TEST: Step 6 - Cleanup")
        fake_screen1:fake_remove()
        print("TEST:   cleanup done")
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
