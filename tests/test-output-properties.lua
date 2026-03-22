---------------------------------------------------------------------------
-- Tests for output Lua object class:
--   1. output global exists and has expected methods
--   2. output.count() returns correct count
--   3. output[1] returns a valid output object
--   4. Output objects have expected read-only properties
--   5. output.get_by_name() works
--   6. screen.output cross-reference works
--   7. Iteration via "for o in output do" works
--   8. virtual property exists and is boolean
--   9. make/model/serial are nil or string (native wlr_output fields)
---------------------------------------------------------------------------

local runner = require("_runner")

print("TEST: Starting output-properties test")

local steps = {
    -- Step 1: output global exists with expected methods
    function()
        print("TEST: Step 1 - Verify output global")
        assert(output ~= nil, "output global is nil")
        assert(type(output.count) == "function",
            "output.count is not a function")
        assert(type(output.get_by_name) == "function",
            "output.get_by_name is not a function")
        assert(type(output.connect_signal) == "function",
            "output.connect_signal is not a function")
        assert(type(output.disconnect_signal) == "function",
            "output.disconnect_signal is not a function")
        return true
    end,

    -- Step 2: output.count() returns correct count
    function()
        print("TEST: Step 2 - Verify output.count()")
        local count = output.count()
        print("TEST:   output.count() = " .. count)
        assert(type(count) == "number", "count is not a number")
        assert(count >= 1, "expected at least 1 output, got " .. count)
        -- Should match screen count (all outputs enabled by default)
        assert(count == screen.count(),
            "output.count() (" .. count .. ") != screen.count() ("
            .. screen.count() .. ")")
        return true
    end,

    -- Step 3: output[1] returns a valid output object
    function()
        print("TEST: Step 3 - Verify output[1]")
        local o = output[1]
        assert(o ~= nil, "output[1] is nil")
        assert(o.valid == true, "output[1].valid is not true")
        print("TEST:   output[1] = " .. tostring(o))
        return true
    end,

    -- Step 4: Output properties
    function()
        print("TEST: Step 4 - Verify output properties")
        local o = output[1]

        -- name (string, e.g. "WL-1" or "HDMI-A-1")
        assert(type(o.name) == "string", "name is not a string: " .. type(o.name))
        print("TEST:   name = " .. o.name)

        -- description (string or nil)
        if o.description then
            assert(type(o.description) == "string",
                "description is not a string")
            print("TEST:   description = " .. o.description)
        end

        -- make/model/serial (nil or string - native wlr_output fields)
        assert(o.make == nil or type(o.make) == "string",
            "make is not nil or string: " .. type(o.make))
        assert(o.model == nil or type(o.model) == "string",
            "model is not nil or string: " .. type(o.model))
        assert(o.serial == nil or type(o.serial) == "string",
            "serial is not nil or string: " .. type(o.serial))
        print("TEST:   make = " .. tostring(o.make))
        print("TEST:   model = " .. tostring(o.model))
        print("TEST:   serial = " .. tostring(o.serial))

        -- physical dimensions (integers)
        assert(type(o.physical_width) == "number",
            "physical_width is not a number")
        assert(type(o.physical_height) == "number",
            "physical_height is not a number")
        print("TEST:   physical = " .. o.physical_width
            .. "x" .. o.physical_height .. " mm")

        -- enabled (boolean)
        assert(type(o.enabled) == "boolean",
            "enabled is not a boolean: " .. type(o.enabled))
        assert(o.enabled == true, "output[1] should be enabled")
        print("TEST:   enabled = " .. tostring(o.enabled))

        -- scale (number)
        assert(type(o.scale) == "number",
            "scale is not a number: " .. type(o.scale))
        print("TEST:   scale = " .. o.scale)

        -- transform (number)
        assert(type(o.transform) == "number",
            "transform is not a number: " .. type(o.transform))
        print("TEST:   transform = " .. o.transform)

        -- virtual (boolean)
        assert(type(o.virtual) == "boolean",
            "virtual is not a boolean: " .. type(o.virtual))
        print("TEST:   virtual = " .. tostring(o.virtual))

        -- modes (table)
        assert(type(o.modes) == "table",
            "modes is not a table: " .. type(o.modes))
        print("TEST:   modes count = " .. #o.modes)
        if #o.modes > 0 then
            local m = o.modes[1]
            assert(type(m.width) == "number", "mode.width not a number")
            assert(type(m.height) == "number", "mode.height not a number")
            assert(type(m.refresh) == "number", "mode.refresh not a number")
            print("TEST:   mode[1] = " .. m.width .. "x" .. m.height
                .. "@" .. m.refresh)
        end

        -- current_mode (table or nil when enabled)
        if o.enabled then
            local cm = o.current_mode
            if cm then
                assert(type(cm.width) == "number",
                    "current_mode.width not a number")
                print("TEST:   current_mode = " .. cm.width .. "x"
                    .. cm.height .. "@" .. cm.refresh)
            end
        end

        -- position (table with x, y)
        assert(type(o.position) == "table",
            "position is not a table: " .. type(o.position))
        assert(type(o.position.x) == "number", "position.x not a number")
        assert(type(o.position.y) == "number", "position.y not a number")
        print("TEST:   position = " .. o.position.x .. ", " .. o.position.y)

        -- adaptive_sync (boolean)
        assert(type(o.adaptive_sync) == "boolean",
            "adaptive_sync is not a boolean")
        print("TEST:   adaptive_sync = " .. tostring(o.adaptive_sync))

        return true
    end,

    -- Step 5: output.get_by_name()
    function()
        print("TEST: Step 5 - Verify output.get_by_name()")
        local o = output[1]
        local found = output.get_by_name(o.name)
        assert(found ~= nil,
            "get_by_name('" .. o.name .. "') returned nil")
        assert(found.name == o.name,
            "get_by_name returned wrong output")
        print("TEST:   get_by_name('" .. o.name .. "') OK")

        -- Non-existent name returns nil
        local missing = output.get_by_name("NONEXISTENT-99")
        assert(missing == nil,
            "get_by_name('NONEXISTENT-99') should return nil")
        print("TEST:   get_by_name('NONEXISTENT-99') == nil OK")
        return true
    end,

    -- Step 6: screen.output cross-reference
    function()
        print("TEST: Step 6 - Verify screen.output cross-reference")
        for s in screen do
            assert(s.output ~= nil,
                "screen " .. s.index .. " has nil output")
            assert(s.output.valid == true,
                "screen " .. s.index .. " output is not valid")
            assert(s.output.screen ~= nil,
                "output.screen is nil")
            print("TEST:   screen " .. s.index .. ".output.name = "
                .. s.output.name)
        end
        return true
    end,

    -- Step 7: Iteration
    function()
        print("TEST: Step 7 - Verify iteration")
        local count = 0
        for o in output do
            count = count + 1
            assert(o ~= nil, "iteration produced nil output")
            assert(o.valid == true,
                "iteration produced invalid output")
            print("TEST:   iterated: " .. o.name)
        end
        assert(count == output.count(),
            "iteration count (" .. count .. ") != output.count() ("
            .. output.count() .. ")")
        print("TEST:   iterated " .. count .. " outputs OK")
        return true
    end,

    -- Step 8: screen.scale delegates to output.scale
    function()
        print("TEST: Step 8 - Verify screen.scale == output.scale")
        for s in screen do
            if s.output and not s.output.virtual then
                assert(s.geometry.width > 0,
                    "screen has zero width")
                assert(s.scale == s.output.scale,
                    "screen.scale (" .. s.scale .. ") != output.scale ("
                    .. s.output.scale .. ")")
                print("TEST:   screen " .. s.index
                    .. " scale = " .. s.scale .. " (matches output)")
            end
        end
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
